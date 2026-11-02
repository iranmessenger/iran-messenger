<?php
defined( 'ABSPATH' ) || exit;

/** Public key directory: device bundles and one-time prekeys. */
class IRM_Keys {

	/** @return array|WP_Error List of array( 'id' => int, 'key' => base64 ). */
	public static function parse_prekeys( $list ) {
		$bad = new WP_Error( 'irm_bad_prekeys', 'Prekey list is malformed.', array( 'status' => 400 ) );
		if ( ! is_array( $list ) || count( $list ) > IRM_MAX_PREKEYS ) {
			return $bad;
		}
		$out = array();
		foreach ( $list as $pk ) {
			if ( ! is_array( $pk ) || ! is_int( $pk['id'] ?? null ) || $pk['id'] < 1
				|| false === IRM_Auth::b64( $pk['key'] ?? null, 33 ) ) {
				return $bad;
			}
			$out[ $pk['id'] ] = array(
				'id'  => $pk['id'],
				'key' => $pk['key'],
			);
		}
		return array_values( $out );
	}

	/** Must be called inside the caller's transaction. Returns new id or 0. */
	public static function insert_device( $identity_id, $role, array $d ) {
		global $wpdb;
		$ok = $wpdb->insert(
			IRM_Schema::table( 'devices' ),
			array(
				'identity_id'     => $identity_id,
				'role'            => $role,
				'auth_key'        => $d['auth_key'],
				'registration_id' => $d['registration_id'],
				'identity_key'    => $d['identity_key'],
				'spk_id'          => $d['spk_id'],
				'spk_pub'         => $d['spk_pub'],
				'spk_sig'         => $d['spk_sig'],
				'created_at'      => time(),
			)
		);
		if ( ! $ok ) {
			return 0;
		}
		$device_id = (int) $wpdb->insert_id;
		return self::insert_prekeys( $device_id, $d['prekeys'] ) ? $device_id : 0;
	}

	private static function insert_prekeys( $device_id, array $prekeys ) {
		global $wpdb;
		foreach ( $prekeys as $pk ) {
			$ok = $wpdb->query(
				$wpdb->prepare(
					'INSERT IGNORE INTO ' . IRM_Schema::table( 'prekeys' ) . ' (device_id, key_id, pub) VALUES (%d, %d, %s)',
					$device_id,
					$pk['id'],
					$pk['key']
				)
			);
			if ( false === $ok ) {
				return false;
			}
		}
		return true;
	}

	public static function prekey_count( $device_id ) {
		global $wpdb;
		return (int) $wpdb->get_var(
			$wpdb->prepare( 'SELECT COUNT(*) FROM ' . IRM_Schema::table( 'prekeys' ) . ' WHERE device_id = %d', $device_id )
		);
	}

	/** POST /keys/prekeys — top up the caller's one-time prekeys. */
	public static function upload_prekeys( WP_REST_Request $request ) {
		global $wpdb;
		$device  = IRM_Auth::device();
		$p       = (array) $request->get_json_params();
		$prekeys = self::parse_prekeys( $p['prekeys'] ?? null );
		if ( is_wp_error( $prekeys ) ) {
			return $prekeys;
		}
		$have = self::prekey_count( (int) $device->id );
		if ( $have + count( $prekeys ) > IRM_MAX_PREKEYS ) {
			return new WP_Error( 'irm_too_many_prekeys', 'Prekey store is full.', array( 'status' => 409 ) );
		}
		$wpdb->query( 'START TRANSACTION' );
		if ( ! self::insert_prekeys( (int) $device->id, $prekeys ) ) {
			$wpdb->query( 'ROLLBACK' );
			return new WP_Error( 'irm_db', 'Could not store prekeys.', array( 'status' => 500 ) );
		}
		$wpdb->query( 'COMMIT' );
		return array( 'prekey_count' => self::prekey_count( (int) $device->id ) );
	}

	/**
	 * GET /keys/{identity_id} — one bundle per active device of that member.
	 * Each call consumes one one-time prekey per device, atomically.
	 */
	public static function bundles( WP_REST_Request $request ) {
		global $wpdb;
		$identity_id = (int) $request['identity_id'];
		$t_pre       = IRM_Schema::table( 'prekeys' );

		$devices = $wpdb->get_results(
			$wpdb->prepare(
				'SELECT d.* FROM ' . IRM_Schema::table( 'devices' ) . ' d
				 JOIN ' . IRM_Schema::table( 'identities' ) . " i ON i.id = d.identity_id
				 WHERE d.identity_id = %d AND d.status = 'active' AND i.status = 'active' ORDER BY d.id",
				$identity_id
			)
		);
		if ( ! $devices ) {
			return new WP_Error( 'irm_not_found', 'No such member.', array( 'status' => 404 ) );
		}

		$out = array();
		foreach ( $devices as $d ) {
			$wpdb->query( 'START TRANSACTION' );
			$pk = $wpdb->get_row(
				$wpdb->prepare( "SELECT id, key_id, pub FROM $t_pre WHERE device_id = %d ORDER BY id LIMIT 1 FOR UPDATE", $d->id )
			);
			if ( $pk ) {
				$wpdb->query( $wpdb->prepare( "DELETE FROM $t_pre WHERE id = %d", $pk->id ) );
			}
			$wpdb->query( 'COMMIT' );

			$out[] = array(
				'device_id'       => (int) $d->id,
				'registration_id' => (int) $d->registration_id,
				'identity_key'    => $d->identity_key,
				'signed_prekey'   => array(
					'id'  => (int) $d->spk_id,
					'key' => $d->spk_pub,
					'sig' => $d->spk_sig,
				),
				'prekey'          => $pk ? array(
					'id'  => (int) $pk->key_id,
					'key' => $pk->pub,
				) : null,
			);
		}
		return array(
			'identity_id' => $identity_id,
			'devices'     => $out,
		);
	}
}
