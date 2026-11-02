<?php
/**
 * Known-answer and round-trip tests for the web push cryptography.
 *
 *   php tests/push_crypto_test.php
 *
 * On Windows, PHP needs to be told where its OpenSSL configuration is:
 *   set OPENSSL_CONF=C:
mppphpextrassslopenssl.cnf
 */
define( 'ABSPATH', __DIR__ );
require __DIR__ . '/../plugin/iran-messenger/includes/class-irm-push.php';

$failed = 0;
function check( $name, $ok ) {
	global $failed;
	$failed += $ok ? 0 : 1;
	echo ( $ok ? 'PASS  ' : 'FAIL  ' ) . $name . "\n";
}
function d( $s ) {
	return IRM_Push::b64u_decode( $s );
}
/** OpenSSL private key from a raw P-256 scalar and its public point. */
function ec_private( $scalar, $point ) {
	$der = hex2bin( '30770201010420' ) . $scalar . hex2bin( 'a00a06082a8648ce3d030107a144034200' ) . $point;
	return openssl_pkey_get_private( "-----BEGIN EC PRIVATE KEY-----\n" . chunk_split( base64_encode( $der ), 64, "\n" ) . "-----END EC PRIVATE KEY-----\n" );
}
/** What a browser does with a received push message (RFC 8291). */
function browser_decrypt( $body, $ua_private, $ua_public, $auth ) {
	$salt      = substr( $body, 0, 16 );
	$idlen     = ord( $body[20] );
	$as_public = substr( $body, 21, $idlen );
	$sealed    = substr( $body, 21 + $idlen );
	$pem       = "-----BEGIN PUBLIC KEY-----\n" . chunk_split( base64_encode( hex2bin( '3059301306072a8648ce3d020106082a8648ce3d030107034200' ) . $as_public ), 64, "\n" ) . "-----END PUBLIC KEY-----\n";
	$shared    = openssl_pkey_derive( $pem, $ua_private, 32 );
	$ikm       = hash_hkdf( 'sha256', $shared, 32, "WebPush: info\0" . $ua_public . $as_public, $auth );
	$key       = hash_hkdf( 'sha256', $ikm, 16, "Content-Encoding: aes128gcm\0", $salt );
	$nonce     = hash_hkdf( 'sha256', $ikm, 12, "Content-Encoding: nonce\0", $salt );
	$plain     = openssl_decrypt( substr( $sealed, 0, -16 ), 'aes-128-gcm', $key, OPENSSL_RAW_DATA, $nonce, substr( $sealed, -16 ) );
	return false === $plain ? false : rtrim( $plain, "\x02" );
}

// ---- RFC 8291, appendix A ----
$plain      = 'When I grow up, I want to be a watermelon';
$as_public  = d( 'BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8' );
$as_private = d( 'yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw' );
$ua_public  = d( 'BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4' );
$ua_private = d( 'q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94' );
$salt       = d( 'DGv6ra1nlYgDCS1FRnbzlw' );
$auth       = d( 'BTBZMqHH6r4Tts7J_aSIgg' );
$expected   = 'DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN';

$sender = ec_private( $as_private, $as_public );
check( 'test vector keys load', false !== $sender && 65 === strlen( $ua_public ) && 16 === strlen( $auth ) );
$body = IRM_Push::encrypt( $plain, $ua_public, $auth, $sender, $salt );
check( 'encryption matches the RFC 8291 example byte for byte', false !== $body && IRM_Push::b64u( $body ) === $expected );

// ---- fresh keys, as in real use ----
$browser = openssl_pkey_new( array( 'curve_name' => 'prime256v1', 'private_key_type' => OPENSSL_KEYTYPE_EC ) );
$det     = openssl_pkey_get_details( $browser );
$point   = "\x04" . str_pad( $det['ec']['x'], 32, "\0", STR_PAD_LEFT ) . str_pad( $det['ec']['y'], 32, "\0", STR_PAD_LEFT );
$secret  = random_bytes( 16 );
$a       = IRM_Push::encrypt( '{"t":"new"}', $point, $secret );
$b       = IRM_Push::encrypt( '{"t":"new"}', $point, $secret );
check( 'a browser can open what the server sealed', '{"t":"new"}' === browser_decrypt( $a, $browser, $point, $secret ) );
check( 'every message uses a fresh key and salt', $a !== $b );
$tampered         = $a;
$tampered[ strlen( $a ) - 20 ] = chr( ord( $tampered[ strlen( $a ) - 20 ] ) ^ 1 );
check( 'a changed message is rejected', false === browser_decrypt( $tampered, $browser, $point, $secret ) );
check( 'another browser cannot open it', false === browser_decrypt( $a, $browser, $point, random_bytes( 16 ) ) );

// ---- VAPID token ----
$server = openssl_pkey_new( array( 'curve_name' => 'prime256v1', 'private_key_type' => OPENSSL_KEYTYPE_EC ) );
openssl_pkey_export( $server, $pem );
$jwt   = IRM_Push::vapid_jwt( 'https://web.push.apple.com', 'https://example.ir/', $pem, 1700000000 );
$parts = explode( '.', (string) $jwt );
check( 'token has three parts', 3 === count( $parts ) );
$claims = json_decode( d( $parts[1] ), true );
check( 'token names the push service and expires within a day', 'https://web.push.apple.com' === $claims['aud'] && 1700000000 + 43200 === $claims['exp'] );
$raw = d( $parts[2] );
check( 'signature is two 32-byte numbers', 64 === strlen( $raw ) );
$int = function ( $n ) {
	$n = ltrim( $n, "\0" );
	if ( '' === $n || ord( $n[0] ) > 0x7f ) {
		$n = "\0" . $n;
	}
	return "\x02" . chr( strlen( $n ) ) . $n;
};
$seq = $int( substr( $raw, 0, 32 ) ) . $int( substr( $raw, 32 ) );
$der = "\x30" . chr( strlen( $seq ) ) . $seq;
check( 'signature verifies with the server public key', 1 === openssl_verify( $parts[0] . '.' . $parts[1], $der, openssl_pkey_get_details( $server )['key'], OPENSSL_ALGO_SHA256 ) );

echo $failed ? "\n$failed FAILED\n" : "\nall passed\n";
exit( $failed ? 1 : 0 );
