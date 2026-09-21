import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../auth/auth_repository.dart';
import 'package:uuid/uuid.dart'; // Ensure to add uuid to pubspec if using locally generated idempotency keys

final walletRepositoryProvider = Provider<WalletRepository>((ref) {
  final supabase = ref.watch(supabaseClientProvider);
  return WalletRepository(supabase);
});

class WalletRepository {
  final SupabaseClient _supabase;

  WalletRepository(this._supabase);

  Stream<Map<String, dynamic>> watchBalance(String userId) {
    return _supabase
        .from('wallets')
        .stream(primaryKey: ['user_id'])
        .eq('user_id', userId)
        .map((events) => events.first);
  }

  Future<void> transferTokens({
    required String toUserId,
    required double amount,
    required String note,
    required String pin,
  }) async {
    final idempotencyKey = const Uuid().v4();
    
    await _supabase.rpc('transfer_tokens', params: {
      'p_to_user': toUserId,
      'p_amount': amount,
      'p_note': note,
      'p_pin': pin,
      'p_idempotency_key': idempotencyKey,
    });
  }
}
