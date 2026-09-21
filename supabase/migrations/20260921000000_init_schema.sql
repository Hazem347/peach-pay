-- Migration: Init Schema

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- 1. Create tables
CREATE TABLE profiles (
    id UUID PRIMARY KEY REFERENCES auth.users(id),
    full_name TEXT,
    username TEXT UNIQUE,
    email TEXT UNIQUE,
    phone TEXT,
    avatar_url TEXT,
    role TEXT CHECK (role IN ('user', 'super_admin')) DEFAULT 'user',
    is_frozen BOOLEAN DEFAULT FALSE,
    pin_hash TEXT, -- hashed via pgcrypto
    pin_attempts INT DEFAULT 0,
    locked_until TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE wallets (
    user_id UUID PRIMARY KEY REFERENCES profiles(id),
    balance NUMERIC(18,2) DEFAULT 0 CHECK (balance >= 0),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE transactions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    type TEXT CHECK (type IN ('transfer', 'mint', 'burn', 'reversal', 'request_payment')),
    from_user UUID REFERENCES profiles(id),
    to_user UUID REFERENCES profiles(id),
    amount NUMERIC(18,2) CHECK (amount > 0),
    note TEXT,
    status TEXT CHECK (status IN ('pending', 'completed', 'failed', 'reversed')),
    idempotency_key TEXT UNIQUE,
    created_by UUID REFERENCES profiles(id),
    reversed_of UUID REFERENCES transactions(id),
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE payment_requests (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    requester UUID REFERENCES profiles(id),
    payer UUID REFERENCES profiles(id),
    amount NUMERIC(18,2) CHECK (amount > 0),
    note TEXT,
    status TEXT CHECK (status IN ('pending', 'accepted', 'declined', 'cancelled')),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE notifications (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES profiles(id),
    title TEXT,
    body TEXT,
    data JSONB,
    read BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE announcements (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title TEXT,
    body TEXT,
    created_by UUID REFERENCES profiles(id),
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE app_settings (
    id INT PRIMARY KEY DEFAULT 1,
    per_transaction_limit NUMERIC(18,2) DEFAULT 10000.00,
    daily_limit NUMERIC(18,2) DEFAULT 50000.00,
    admin_emails TEXT[],
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE admin_audit_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    admin_id UUID REFERENCES profiles(id),
    action TEXT,
    target TEXT,
    details JSONB,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 2. Trigger to auto-create profile and wallet on signup
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
DECLARE
    is_admin BOOLEAN := FALSE;
BEGIN
    SELECT (NEW.email = ANY(admin_emails)) INTO is_admin FROM app_settings WHERE id = 1;
    
    INSERT INTO public.profiles (id, email, full_name, role)
    VALUES (NEW.id, NEW.email, NEW.raw_user_meta_data->>'full_name', CASE WHEN is_admin THEN 'super_admin' ELSE 'user' END);
    
    INSERT INTO public.wallets (user_id, balance)
    VALUES (NEW.id, 0);
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE PROCEDURE public.handle_new_user();

-- 3. Row Level Security
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE wallets ENABLE ROW LEVEL SECURITY;
ALTER TABLE transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE payment_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE announcements ENABLE ROW LEVEL SECURITY;
ALTER TABLE app_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin_audit_log ENABLE ROW LEVEL SECURITY;

-- Profiles Policies
CREATE POLICY "Public profiles are viewable by everyone" ON profiles FOR SELECT USING (true);
CREATE POLICY "Users can update own profile" ON profiles FOR UPDATE USING (auth.uid() = id);

-- Wallets Policies
CREATE POLICY "Users can view own wallet" ON wallets FOR SELECT USING (auth.uid() = user_id);

-- Transactions Policies
CREATE POLICY "Users can view own transactions" ON transactions FOR SELECT USING (auth.uid() = from_user OR auth.uid() = to_user);

-- Payment Requests Policies
CREATE POLICY "Users can view own payment requests" ON payment_requests FOR SELECT USING (auth.uid() = requester OR auth.uid() = payer);
CREATE POLICY "Users can insert payment requests" ON payment_requests FOR INSERT WITH CHECK (auth.uid() = requester);
CREATE POLICY "Users can update own payment requests" ON payment_requests FOR UPDATE USING (auth.uid() = requester OR auth.uid() = payer);

-- Notifications Policies
CREATE POLICY "Users can view own notifications" ON notifications FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "Users can update own notifications" ON notifications FOR UPDATE USING (auth.uid() = user_id);

-- Announcements Policies
CREATE POLICY "Announcements are viewable by everyone" ON announcements FOR SELECT USING (true);

-- App Settings Policies
CREATE POLICY "App settings are viewable by everyone" ON app_settings FOR SELECT USING (true);

-- Admin Audit Log Policies
CREATE POLICY "Only super_admin can view audit log" ON admin_audit_log FOR SELECT USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'super_admin')
);

-- Super admin policies (can view all, update where appropriate)
CREATE POLICY "Super admin can view all profiles" ON profiles FOR SELECT USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'super_admin')
);
CREATE POLICY "Super admin can view all wallets" ON wallets FOR SELECT USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'super_admin')
);
CREATE POLICY "Super admin can view all transactions" ON transactions FOR SELECT USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'super_admin')
);

REVOKE INSERT, UPDATE, DELETE ON wallets FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON transactions FROM authenticated;

-- 4. RPC Functions (Security Definer)
CREATE OR REPLACE FUNCTION transfer_tokens(p_to_user UUID, p_amount NUMERIC, p_note TEXT, p_pin TEXT, p_idempotency_key TEXT)
RETURNS UUID AS $$
DECLARE
    v_from_user UUID := auth.uid();
    v_sender_wallet wallets%ROWTYPE;
    v_receiver_wallet wallets%ROWTYPE;
    v_sender_profile profiles%ROWTYPE;
    v_transaction_id UUID;
BEGIN
    IF p_amount <= 0 THEN
        RAISE EXCEPTION 'Amount must be greater than 0';
    END IF;
    IF v_from_user = p_to_user THEN
        RAISE EXCEPTION 'Cannot transfer to self';
    END IF;

    SELECT * INTO v_sender_profile FROM profiles WHERE id = v_from_user;
    IF v_sender_profile.is_frozen THEN
        RAISE EXCEPTION 'Account is frozen';
    END IF;
    
    IF v_sender_profile.pin_hash IS NULL OR crypt(p_pin, v_sender_profile.pin_hash) != v_sender_profile.pin_hash THEN
        RAISE EXCEPTION 'Invalid PIN';
    END IF;

    IF v_from_user < p_to_user THEN
        SELECT * INTO v_sender_wallet FROM wallets WHERE user_id = v_from_user FOR UPDATE;
        SELECT * INTO v_receiver_wallet FROM wallets WHERE user_id = p_to_user FOR UPDATE;
    ELSE
        SELECT * INTO v_receiver_wallet FROM wallets WHERE user_id = p_to_user FOR UPDATE;
        SELECT * INTO v_sender_wallet FROM wallets WHERE user_id = v_from_user FOR UPDATE;
    END IF;

    IF v_receiver_wallet.user_id IS NULL THEN
        RAISE EXCEPTION 'Receiver not found';
    END IF;

    IF v_sender_wallet.balance < p_amount THEN
        RAISE EXCEPTION 'Insufficient balance';
    END IF;

    UPDATE wallets SET balance = balance - p_amount, updated_at = NOW() WHERE user_id = v_from_user;
    UPDATE wallets SET balance = balance + p_amount, updated_at = NOW() WHERE user_id = p_to_user;

    INSERT INTO transactions (type, from_user, to_user, amount, note, status, idempotency_key, created_by)
    VALUES ('transfer', v_from_user, p_to_user, p_amount, p_note, 'completed', p_idempotency_key, v_from_user)
    RETURNING id INTO v_transaction_id;

    RETURN v_transaction_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


CREATE OR REPLACE FUNCTION admin_mint(p_to_user UUID, p_amount NUMERIC, p_reason TEXT, p_idempotency_key TEXT)
RETURNS UUID AS $$
DECLARE
    v_admin_id UUID := auth.uid();
    v_admin_role TEXT;
    v_transaction_id UUID;
BEGIN
    SELECT role INTO v_admin_role FROM profiles WHERE id = v_admin_id;
    IF v_admin_role != 'super_admin' THEN
        RAISE EXCEPTION 'Unauthorized';
    END IF;

    IF p_amount <= 0 THEN
        RAISE EXCEPTION 'Amount must be greater than 0';
    END IF;

    PERFORM 1 FROM wallets WHERE user_id = p_to_user FOR UPDATE;
    UPDATE wallets SET balance = balance + p_amount, updated_at = NOW() WHERE user_id = p_to_user;

    INSERT INTO transactions (type, from_user, to_user, amount, note, status, idempotency_key, created_by)
    VALUES ('mint', NULL, p_to_user, p_amount, p_reason, 'completed', p_idempotency_key, v_admin_id)
    RETURNING id INTO v_transaction_id;

    INSERT INTO admin_audit_log (admin_id, action, target, details)
    VALUES (v_admin_id, 'mint', p_to_user::text, jsonb_build_object('amount', p_amount, 'reason', p_reason, 'tx_id', v_transaction_id));

    RETURN v_transaction_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION set_pin(p_pin TEXT)
RETURNS VOID AS $$
BEGIN
    UPDATE profiles 
    SET pin_hash = crypt(p_pin, gen_salt('bf'))
    WHERE id = auth.uid();
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Seed Settings
INSERT INTO app_settings (id, per_transaction_limit, daily_limit, admin_emails) 
VALUES (1, 10000.00, 50000.00, ARRAY['admin@peachpay.app'])
ON CONFLICT (id) DO NOTHING;
