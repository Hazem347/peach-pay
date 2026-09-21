# Peach Pay - Setup & Release Guide

Peach Pay is a closed-loop digital wallet MVP built with Flutter and Supabase.

## 1. Supabase Setup
1. Go to [Supabase](https://supabase.com/) and create a new project.
2. Under **SQL Editor**, open the `supabase/migrations/20260921000000_init_schema.sql` file from this repository and run it. This creates tables, RLS policies, triggers, and RPCs.
3. Note your **Project URL** and **anon public key** from `Project Settings -> API`. You will need to add these to the Flutter app.

## 2. Google Sign-In Setup
1. Go to the [Google Cloud Console](https://console.cloud.google.com/) and create a new project.
2. Configure the OAuth consent screen.
3. Create OAuth client IDs for:
   - **Android**: You will need your SHA-1 fingerprint (run `./gradlew signingReport` in the `android` folder once generated).
   - **iOS**: (If building for iOS) Add your bundle ID.
   - **Web**: (For Supabase configuration)
4. Go back to Supabase -> **Authentication** -> **Providers** -> **Google** and add the Web Client ID and Secret.

## 3. Firebase / FCM Setup
1. Go to [Firebase Console](https://console.firebase.google.com/) and create a project.
2. Register the Android and iOS apps.
3. Download `google-services.json` and place it in `android/app/`.
4. Download `GoogleService-Info.plist` and place it in `ios/Runner/`.
5. Note: Push notifications will require further backend integration with Supabase Edge Functions or a similar trigger to push via FCM API.

## 4. Super Admin Configuration
By default, the SQL migration seeds `admin@peachpay.app` as the admin in the `app_settings` table.
To change this to your email:
```sql
UPDATE app_settings 
SET admin_emails = ARRAY['your_email@gmail.com'] 
WHERE id = 1;
```
When you sign up with this email, the trigger will automatically set your role to `super_admin` instead of `user`.

## 5. Running the App
Since Flutter could not be found in the current environment PATH during generation, ensure Flutter is installed on your machine.
1. Run `flutter pub get` in this directory to download dependencies.
2. In `lib/main.dart`, uncomment the `Supabase.initialize` block and add your URL and Anon Key (or use `.env` / `--dart-define`).
3. Run `flutter run` on an emulator or physical device.

---

## Build and Release Guide

### 1. Signing Key Setup (Android)
1. Generate a keystore:
   ```bash
   keytool -genkey -v -keystore release.jks -keyalg RSA -keysize 2048 -validity 10000 -alias peachpay
   ```
2. Create a file named `android/key.properties` with:
   ```properties
   storePassword=yourpassword
   keyPassword=yourpassword
   keyAlias=peachpay
   storeFile=release.jks
   ```
3. Update `android/app/build.gradle` to use the signing config.

### 2. Building the App
- APK: `flutter build apk --release` (outputs to `build/app/outputs/flutter-apk/app-release.apk`)
- App Bundle: `flutter build appbundle --release` (for Play Store)

### 3. Distribution
Upload the generated `app-release.apk` to Firebase App Distribution to share it easily with your friends. Add their emails as testers.

---

## Test Checklist

Before full deployment, verify the following manually:
- [ ] **Normal Transfer**: User A sends Rs 100 to User B. Balances update correctly.
- [ ] **Insufficient Balance**: User A tries to send Rs 1,000,000. It must fail.
- [ ] **Double-tap Duplicate**: Send the exact same request twice with the same idempotency key (mocked or rapidly tapped). The RPC should reject the second attempt as a unique constraint violation on `idempotency_key`.
- [ ] **Frozen User**: Freeze User A from the Admin dashboard. User A attempts to send money. It must fail.
- [ ] **Admin Mint**: Log in as `super_admin`. Mint Rs 500 to User B. Balance increases, audit log created.
- [ ] **Transaction Reversal**: As Admin, reverse User A's transaction. Balances must revert, and a 'reversal' tx must be created.
- [ ] **RLS Bypass Attempt**: Authenticate as a normal user. Use a direct Supabase REST call to try and `INSERT` into the `transactions` table directly. The request MUST be denied (403 or empty result depending on RLS).
