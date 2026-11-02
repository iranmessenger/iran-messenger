<?php
defined( 'ABSPATH' ) || exit;

/**
 * Server-signed responses.
 *
 * Every API answer carries an Ed25519 signature over its status, the
 * request's nonce and its exact body. Clients pin the public key when they
 * enrol, so anything standing between them and this server (a relay, a
 * proxy) cannot forge "message accepted", alter an answer, or replay an
 * old one for a new request.
 */
class IRM_Signing {

	private static function secret() {
		$stored = get_option( 'irm_server_key' );
		$raw    = is_string( $stored ) ? base64_decode( $stored, true ) : false;
		if ( false === $raw || SODIUM_CRYPTO_SIGN_SECRETKEYBYTES !== strlen( $raw ) ) {
			$raw = sodium_crypto_sign_secretkey( sodium_crypto_sign_keypair() );
			update_option( 'irm_server_key', base64_encode( $raw ), false );
		}
		return $raw;
	}

	/** Base64 public key that clients pin. */
	public static function public_key() {
		return base64_encode( sodium_crypto_sign_publickey_from_secretkey( self::secret() ) );
	}

	/** Runs just before the body is written, when its final bytes are known. */
	public static function sign_response( $result, $server, $request ) {
		if ( 0 !== strpos( $request->get_route(), '/' . IRM_REST_NS ) || headers_sent() ) {
			return $result;
		}
		$nonce = (string) $request->get_header( 'x_irm_nonce' );
		if ( false === IRM_Auth::b64( $nonce, 16 ) ) {
			$nonce = '';
		}
		$message = implode(
			"\n",
			array(
				'IRM1-RESP',
				(int) http_response_code(),
				$nonce,
				hash( 'sha256', (string) wp_json_encode( $result ) ),
			)
		);
		header( 'X-IRM-Server-Sig: ' . base64_encode( sodium_crypto_sign_detached( $message, self::secret() ) ) );
		return $result;
	}

	/** Private relays configured by the administrator: array of [url, key]. */
	public static function relays() {
		$out = array();
		foreach ( (array) get_option( 'irm_relays', array() ) as $r ) {
			if ( is_array( $r ) && ! empty( $r['url'] ) && ! empty( $r['key'] ) ) {
				$out[] = array(
					'url' => (string) $r['url'],
					'key' => (string) $r['key'],
				);
			}
		}
		return $out;
	}

	/** Parses the admin textarea: one "https://site|key" per line. */
	public static function save_relays( $text ) {
		$list = array();
		foreach ( preg_split( '/\r\n|\r|\n/', (string) $text ) as $line ) {
			$parts = array_map( 'trim', explode( '|', $line, 2 ) );
			if ( 2 !== count( $parts ) ) {
				continue;
			}
			$url = untrailingslashit( esc_url_raw( $parts[0], array( 'https', 'http' ) ) );
			if ( '' !== $url && preg_match( '/^[A-Za-z0-9_-]{16,80}$/', $parts[1] ) ) {
				$list[] = array(
					'url' => $url,
					'key' => $parts[1],
				);
			}
		}
		update_option( 'irm_relays', array_slice( $list, 0, 10 ), false );
	}
}
