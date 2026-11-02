<?php
defined( 'ABSPATH' ) || exit;

/**
 * Temporary store for encrypted attachments.
 *
 * Clients encrypt before upload and share the key only inside E2EE
 * messages, so files here are opaque. A blob is kept until every recipient
 * device has fetched it or IRM_MEDIA_TTL passes, whichever comes first.
 * Nothing is registered in the WordPress media library.
 */
class IRM_Media {

	/** Storage directory, outside the web root whenever the host allows it. */
	public static function dir() {
		if ( defined( 'IRM_MEDIA_DIR' ) ) {
			$dir = IRM_MEDIA_DIR;
		} else {
			$dir = dirname( untrailingslashit( ABSPATH ) ) . '/irm_media';
			if ( ! is_dir( $dir ) && ! @mkdir( $dir, 0700 ) ) { // phpcs:ignore WordPress.PHP.NoSilencedErrors
				$dir = WP_CONTENT_DIR . '/uploads/irm_media';
			}
		}
		if ( ! is_dir( $dir ) ) {
			wp_mkdir_p( $dir );
		}
		// Harmless outside the web root; essential if we had to fall back inside it.
		if ( ! file_exists( $dir . '/.htaccess' ) ) {
			file_put_contents( $dir . '/.htaccess', "Require all denied\nDeny from all\n" );
			file_put_contents( $dir . '/index.php', "<?php\n" );
		}
		return $dir;
	}

	private static function path( $public_id ) {
		return self::dir() . '/' . $public_id . '.bin';
	}

	private static function row( $public_id ) {
		global $wpdb;
		return $wpdb->get_row(
			$wpdb->prepare( 'SELECT * FROM ' . IRM_Schema::table( 'media' ) . ' WHERE public_id = %s', $public_id )
		);
	}

	private static function not_found() {
		// One answer for missing, expired and not-yours: ids reveal nothing.
		return new WP_Error( 'irm_media_gone', 'This file is not available.', array( 'status' => 404 ) );
	}

	/** POST /media/uploads */
	public static function start( WP_REST_Request $request ) {
		global $wpdb;
		$device = IRM_Auth::device();
		$p      = (array) $request->get_json_params();
		$size   = $p['size'] ?? null;
		$sha    = $p['sha256'] ?? null;
		$to     = $p['recipients'] ?? null;

		if ( ! is_int( $size ) || $size < 1 || $size > IRM_MEDIA_MAX_BYTES
			|| ! is_string( $sha ) || ! preg_match( '/^[0-9a-f]{64}$/', $sha )
			|| ! is_array( $to ) || ! $to || count( $to ) > IRM_MAX_ENVELOPES_PER_MESSAGE ) {
			return new WP_Error( 'irm_bad_media', 'Upload request is malformed or too large.', array( 'status' => 400 ) );
		}
		foreach ( $to as $id ) {
			if ( ! is_int( $id ) || $id < 1 ) {
				return new WP_Error( 'irm_bad_media', 'Recipient list is malformed.', array( 'status' => 400 ) );
			}
		}
		$to = array_values( array_unique( $to ) );

		$t_med = IRM_Schema::table( 'media' );
		$now   = time();
		$used  = (int) $wpdb->get_var(
			$wpdb->prepare( "SELECT COALESCE(SUM(size),0) FROM $t_med WHERE owner_device = %d AND expires_at > %d", $device->id, $now )
		);
		if ( $used + $size > IRM_MEDIA_QUOTA_BYTES ) {
			return new WP_Error( 'irm_media_quota', 'Storage quota reached. Try again after pending files are delivered.', array( 'status' => 413 ) );
		}

		// The recipient set is fixed now; devices added later never gain access.
		$marks  = implode( ',', array_fill( 0, count( $to ), '%d' ) );
		$active = (int) $wpdb->get_var(
			$wpdb->prepare( 'SELECT COUNT(*) FROM ' . IRM_Schema::table( 'devices' ) . " WHERE status = 'active' AND id IN ($marks)", $to )
		);
		if ( count( $to ) !== $active ) {
			return new WP_Error( 'irm_stale_devices', 'A recipient device is unknown or revoked. Refresh keys and retry.', array( 'status' => 409 ) );
		}

		$public_id = bin2hex( random_bytes( 16 ) );
		$wpdb->query( 'START TRANSACTION' );
		$ok = $wpdb->insert(
			$t_med,
			array(
				'public_id'    => $public_id,
				'owner_device' => $device->id,
				'size'         => $size,
				'sha256'       => $sha,
				'chunk_size'   => IRM_MEDIA_CHUNK,
				'created_at'   => $now,
				'expires_at'   => $now + IRM_MEDIA_TTL,
			)
		);
		$media_id = (int) $wpdb->insert_id;
		foreach ( $to as $id ) {
			$ok = $ok && $wpdb->insert(
				IRM_Schema::table( 'media_recipients' ),
				array(
					'media_id'  => $media_id,
					'device_id' => $id,
				)
			);
		}
		if ( ! $ok ) {
			$wpdb->query( 'ROLLBACK' );
			return new WP_Error( 'irm_db', 'Could not start upload.', array( 'status' => 500 ) );
		}
		$wpdb->query( 'COMMIT' );

		return new WP_REST_Response(
			array(
				'media_id'   => $public_id,
				'chunk_size' => IRM_MEDIA_CHUNK,
				'next_chunk' => 0,
			),
			201
		);
	}

	/** GET /media/uploads/{id} — where to resume. Owner only. */
	public static function status( WP_REST_Request $request ) {
		$m = self::row( $request['media_id'] );
		if ( ! $m || (int) $m->owner_device !== (int) IRM_Auth::device()->id || $m->expires_at < time() ) {
			return self::not_found();
		}
		return array(
			'next_chunk' => (int) $m->chunks,
			'chunk_size' => (int) $m->chunk_size,
			'complete'   => (bool) $m->complete,
		);
	}

	/** POST /media/uploads/{id}/chunks — { n, data(base64) }. Idempotent per chunk. */
	public static function chunk( WP_REST_Request $request ) {
		global $wpdb;
		$m = self::row( $request['media_id'] );
		if ( ! $m || (int) $m->owner_device !== (int) IRM_Auth::device()->id || $m->expires_at < time() ) {
			return self::not_found();
		}
		$p    = (array) $request->get_json_params();
		$n    = $p['n'] ?? null;
		$data = IRM_Auth::b64( $p['data'] ?? null );
		$next = (int) $m->chunks;

		if ( $m->complete || ( is_int( $n ) && $n < $next ) ) {
			return array(
				'next_chunk' => $next,
				'complete'   => (bool) $m->complete,
			);
		}
		$piece  = (int) $m->chunk_size;
		$total  = (int) ceil( $m->size / $piece );
		$expect = ( $n === $total - 1 ) ? $m->size - $n * $piece : $piece;
		if ( ! is_int( $n ) || $n !== $next || false === $data || strlen( $data ) !== (int) $expect ) {
			return new WP_Error(
				'irm_bad_chunk',
				'Unexpected chunk.',
				array(
					'status'     => 409,
					'next_chunk' => $next,
				)
			);
		}

		// Written at an absolute offset, so repeating a chunk cannot corrupt the file.
		$path = self::path( $m->public_id );
		$fh   = fopen( $path, 'c+b' );
		if ( ! $fh || 0 !== fseek( $fh, $n * $piece ) || strlen( $data ) !== fwrite( $fh, $data ) ) {
			return new WP_Error( 'irm_storage', 'Could not store chunk.', array( 'status' => 507 ) );
		}
		fflush( $fh );
		fclose( $fh );

		$complete = ( $n === $total - 1 );
		if ( $complete && ! hash_equals( $m->sha256, hash_file( 'sha256', $path ) ) ) {
			self::remove( $m );
			return new WP_Error( 'irm_media_corrupt', 'Uploaded file did not match its checksum. Start again.', array( 'status' => 422 ) );
		}
		$wpdb->update(
			IRM_Schema::table( 'media' ),
			array(
				'chunks'   => $n + 1,
				'complete' => $complete ? 1 : 0,
			),
			array( 'id' => $m->id )
		);
		return array(
			'next_chunk' => $n + 1,
			'complete'   => $complete,
		);
	}

	/** Loads a complete, unexpired blob the caller is a recipient of. */
	private static function for_recipient( $public_id ) {
		global $wpdb;
		$m = self::row( $public_id );
		if ( ! $m || ! $m->complete || $m->expires_at < time() ) {
			return null;
		}
		$allowed = $wpdb->get_var(
			$wpdb->prepare(
				'SELECT 1 FROM ' . IRM_Schema::table( 'media_recipients' ) . ' WHERE media_id = %d AND device_id = %d',
				$m->id,
				IRM_Auth::device()->id
			)
		);
		return $allowed ? $m : null;
	}

	/** GET /media/{id}?offset=N — one slice, base64 in JSON. */
	public static function download( WP_REST_Request $request ) {
		$m = self::for_recipient( $request['media_id'] );
		if ( ! $m ) {
			return self::not_found();
		}
		$offset = (int) $request->get_param( 'offset' );
		$path   = self::path( $m->public_id );
		if ( $offset < 0 || $offset >= (int) $m->size || ! is_readable( $path ) ) {
			return self::not_found();
		}
		$data = file_get_contents( $path, false, null, $offset, IRM_MEDIA_CHUNK );
		return array(
			'total' => (int) $m->size,
			'next'  => $offset + strlen( $data ),
			'data'  => base64_encode( $data ),
		);
	}

	/** POST /media/{id}/done — this device has the file; delete when all do. */
	public static function done( WP_REST_Request $request ) {
		global $wpdb;
		$m = self::for_recipient( $request['media_id'] );
		if ( ! $m ) {
			return self::not_found();
		}
		$t_rec = IRM_Schema::table( 'media_recipients' );
		$wpdb->query(
			$wpdb->prepare( "UPDATE $t_rec SET done_at = %d WHERE media_id = %d AND device_id = %d AND done_at = 0", time(), $m->id, IRM_Auth::device()->id )
		);
		$left = (int) $wpdb->get_var( $wpdb->prepare( "SELECT COUNT(*) FROM $t_rec WHERE media_id = %d AND done_at = 0", $m->id ) );
		if ( 0 === $left ) {
			self::remove( $m );
		}
		return array( 'deleted' => 0 === $left );
	}

	/**
	 * POST /media/{id}/delete — the sender deleted the message for everyone:
	 * the file goes at once, whether or not it was fetched. Sender only.
	 */
	public static function take_back( WP_REST_Request $request ) {
		$m = self::row( $request['media_id'] );
		if ( ! $m || (int) $m->owner_device !== (int) IRM_Auth::device()->id ) {
			return self::not_found();
		}
		self::remove( $m );
		return array( 'deleted' => true );
	}

	private static function remove( $m ) {
		global $wpdb;
		$path = self::path( $m->public_id );
		if ( file_exists( $path ) ) {
			unlink( $path );
		}
		$wpdb->delete( IRM_Schema::table( 'media_recipients' ), array( 'media_id' => $m->id ) );
		$wpdb->delete( IRM_Schema::table( 'media' ), array( 'id' => $m->id ) );
	}

	/** Hourly: remove expired blobs. Expiry is already enforced on read. */
	public static function cleanup() {
		global $wpdb;
		$rows = $wpdb->get_results(
			$wpdb->prepare( 'SELECT * FROM ' . IRM_Schema::table( 'media' ) . ' WHERE expires_at < %d LIMIT 200', time() )
		);
		foreach ( $rows as $m ) {
			self::remove( $m );
		}
	}
}
