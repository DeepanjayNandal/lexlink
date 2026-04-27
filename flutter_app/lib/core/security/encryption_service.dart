// lib/core/security/encryption_service.dart
import 'dart:typed_data';
import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart' as dartcrypto;
import 'package:convert/convert.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:logger/logger.dart';

class EncryptionService {
  // We'll use ChaCha20-Poly1305 as specified in the requirements
  final algorithm = Chacha20.poly1305Aead();
  final _logger = Logger();
  final String _keysPrefix = 'encryption_keys_';

  // Generate a new key for encryption/decryption
  Future<SecretKey> generateKey() async {
    return await algorithm.newSecretKey();
  }

  // Check if a key exists in storage
  Future<bool> hasKey(String keyId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey(_keysPrefix + keyId);
  }

  // Store a key with an identifier
  Future<void> storeKey(String keyId, SecretKey key) async {
    final prefs = await SharedPreferences.getInstance();
    final keyString = await exportKey(key);
    await prefs.setString(_keysPrefix + keyId, keyString);
    _logger.d('Stored key with ID: $keyId');
  }

  // Retrieve a key by its identifier
  Future<SecretKey> getKey(String keyId) async {
    final prefs = await SharedPreferences.getInstance();
    final keyString = prefs.getString(_keysPrefix + keyId);

    if (keyString == null) {
      throw Exception('Key not found: $keyId');
    }

    final key = await importKey(keyString);
    _logger.d('Retrieved key with ID: $keyId');
    return key;
  }

  // Delete a key
  Future<void> deleteKey(String keyId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keysPrefix + keyId);
    _logger.d('Deleted key with ID: $keyId');
  }

  // Export a key to a string (for storage or transmission)
  Future<String> exportKey(SecretKey key) async {
    final keyBytes = await key.extractBytes();
    return hex.encode(keyBytes);
  }

  // Import a key from a string
  Future<SecretKey> importKey(String keyHex) async {
    final keyBytes = Uint8List.fromList(hex.decode(keyHex));
    return SecretKey(keyBytes);
  }

  // Encrypt a message with a given key
  Future<String> encrypt(String message, SecretKey key) async {
    // Convert the message to bytes
    final messageBytes = utf8.encode(message);

    // Generate a random nonce (never reuse this for the same key!)
    final nonce = algorithm.newNonce();

    // Encrypt the message
    final secretBox = await algorithm.encrypt(
      messageBytes,
      secretKey: key,
      nonce: nonce,
    );

    // Combine the nonce and cipherText for storage
    final combined = {
      'nonce': base64.encode(nonce),
      'cipherText': base64.encode(secretBox.cipherText),
      'mac': base64.encode(secretBox.mac.bytes),
    };

    // Return as a JSON string
    return jsonEncode(combined);
  }

  // Decrypt a message with a given key
  Future<String> decrypt(String encryptedMessage, SecretKey key) async {
    // Parse the JSON string
    final combined = jsonDecode(encryptedMessage);

    // Extract the components
    final nonce = base64.decode(combined['nonce']);
    final cipherText = base64.decode(combined['cipherText']);
    final mac = Mac(base64.decode(combined['mac']));

    // Recreate the SecretBox
    final secretBox = SecretBox(
      cipherText,
      nonce: nonce,
      mac: mac,
    );

    // Decrypt the message
    final decryptedBytes = await algorithm.decrypt(
      secretBox,
      secretKey: key,
    );

    // Convert the decrypted bytes back to a string
    return utf8.decode(decryptedBytes);
  }

  Future<Map<String, String>> deriveSessionKeys(
      String sharedSecretB64, String sessionId) async {
    final hkdf = Hkdf(hmac: Hmac(Sha256()), outputLength: 32);
    final salt = dartcrypto.sha256.convert(utf8.encode(sessionId)).bytes;
    final shared = SecretKey(base64Decode(sharedSecretB64));
    final sendKey = await hkdf.deriveKey(
        secretKey: shared, nonce: salt, info: utf8.encode('LexLink:SEND:v1'));
    final recvKey = await hkdf.deriveKey(
        secretKey: shared, nonce: salt, info: utf8.encode('LexLink:RECV:v1'));
    return {
      'sendKey': base64Encode(await sendKey.extractBytes()),
      'recvKey': base64Encode(await recvKey.extractBytes()),
    };
  }

  Future<List<int>> generateNonce(String keyBase64, int counter) async {
    final hkdf = Hkdf(hmac: Hmac(Sha256()), outputLength: 24);
    final key = SecretKey(base64Decode(keyBase64));
    final bd = ByteData(8)..setUint64(0, counter, Endian.big);
    final info =
        Uint8List.fromList(utf8.encode('nonce:') + bd.buffer.asUint8List());
    final secret =
        await hkdf.deriveKey(secretKey: key, nonce: Uint8List(0), info: info);
    return await secret.extractBytes();
  }

  Future<String> encryptMessage(String message, String keyBase64, int counter,
      Map<String, dynamic> headers) async {
    final key = SecretKey(base64Decode(keyBase64));
    final aad = utf8.encode(jsonEncode({'v': 1, 'ctr': counter, ...headers}));
    final nonce = await generateNonce(keyBase64, counter);
    final algo = Chacha20.poly1305Aead();
    final box = await algo.encrypt(utf8.encode(message),
        secretKey: key, nonce: nonce, aad: aad);
    return jsonEncode({
      'headers': {'v': 1, 'ctr': counter, ...headers},
      'ciphertext': base64Encode(box.cipherText),
      'tag': base64Encode(box.mac.bytes),
    });
  }

  Future<String> decryptMessage(
      String encryptedMessage, String keyBase64) async {
    final parsed = jsonDecode(encryptedMessage) as Map<String, dynamic>;
    final headers = parsed['headers'] as Map<String, dynamic>;
    final ctr = headers['ctr'] as int;

    final key = SecretKey(base64Decode(keyBase64));
    final aad = utf8.encode(jsonEncode(headers));
    final nonce = await generateNonce(keyBase64, ctr);

    final algo = Chacha20.poly1305Aead();
    final box = SecretBox(
      base64Decode(parsed['ciphertext'] as String),
      nonce: nonce,
      mac: Mac(base64Decode(parsed['tag'] as String)),
    );

    final plaintext = await algo.decrypt(box, secretKey: key, aad: aad);
    return utf8.decode(plaintext);
  }
}
