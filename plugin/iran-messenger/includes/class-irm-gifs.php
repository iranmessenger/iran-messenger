<?php
defined( 'ABSPATH' ) || exit;

/**
 * The shared GIF collection every member can pick from.
 *
 * Two sources: files the administrator uploads, and (optionally) what is
 * currently popular on GIPHY. Popular GIFs are fetched by this server on
 * request and passed through, so the outside service only ever sees the
 * server and never learns which member looked at or sent what. Nothing
 * from GIPHY is kept on disk.
 *
 * When this server cannot reach GIPHY, the same request goes through the
 * push gateway gateway abroad (if one is set). After a direct failure the
 * gateway is used first for ten minutes, then the direct way is tried
 * again.
 */
class IRM_Gifs {

	const MAX_BYTES  = 3145728; // 3 MB per item
	const MAX_PACK   = 60;
	const TREND_SIZE = 24;

	private static $types = array(
		'gif'  => 'image/gif',
		'webp' => 'image/webp',
		'mp4'  => 'video/mp4',
	);

	private static function dir() {
		$dir = IRM_Media::dir() . '/gifs';
		if ( ! is_dir( $dir ) ) {
			wp_mkdir_p( $dir );
		}
		return $dir;
	}

	/** [ id => [ mime, size, name ] ] of uploaded items. */
	public static function pack() {
		$p = get_option( 'irm_gif_pack' );
		return is_array( $p ) ? $p : array();
	}

	// ---------------------------------------------------------------
	// Administrator's own collection
	// ---------------------------------------------------------------

	/** Stores one uploaded file ($_FILES entry). Returns an error text or ''. */
	public static function add_upload( $file ) {
		if ( empty( $file['tmp_name'] ) || ! is_uploaded_file( $file['tmp_name'] ) ) {
			return __( 'No file was received.', 'iran-messenger' );
		}
		$ext = strtolower( pathinfo( (string) $file['name'], PATHINFO_EXTENSION ) );
		if ( ! isset( self::$types[ $ext ] ) ) {
			return __( 'Only GIF, WebP and MP4 files can be added.', 'iran-messenger' );
		}
		$size = (int) filesize( $file['tmp_name'] );
		if ( $size < 1 || $size > self::MAX_BYTES ) {
			return __( 'Each file must be smaller than 3 MB.', 'iran-messenger' );
		}
		// The first bytes must agree with the extension.
		$head  = (string) file_get_contents( $file['tmp_name'], false, null, 0, 12 );
		$looks = 'gif' === $ext ? 0 === strpos( $head, 'GIF8' )
			: ( 'webp' === $ext ? 'RIFF' === substr( $head, 0, 4 ) && 'WEBP' === substr( $head, 8, 4 )
			: 'ftyp' === substr( $head, 4, 4 ) );
		if ( ! $looks ) {
			return __( 'This file is not what its name says.', 'iran-messenger' );
		}
		$pack = self::pack();
		if ( count( $pack ) >= self::MAX_PACK ) {
			return __( 'The collection is full; remove some items first.', 'iran-messenger' );
		}
		$id = 'p' . bin2hex( random_bytes( 8 ) );
		if ( ! move_uploaded_file( $file['tmp_name'], self::dir() . '/' . $id ) ) {
			return __( 'The file could not be stored.', 'iran-messenger' );
		}
		$pack[ $id ] = array(
			'mime' => self::$types[ $ext ],
			'size' => $size,
			'name' => sanitize_file_name( (string) $file['name'] ),
		);
		update_option( 'irm_gif_pack', $pack, false );
		return '';
	}

	public static function remove( $id ) {
		$pack = self::pack();
		if ( isset( $pack[ $id ] ) ) {
			@unlink( self::dir() . '/' . $id ); // phpcs:ignore
			unset( $pack[ $id ] );
			update_option( 'irm_gif_pack', $pack, false );
		}
	}

	// ---------------------------------------------------------------
	// Popular GIFs from the internet
	// ---------------------------------------------------------------

	private static function giphy_host( $url ) {
		$p = wp_parse_url( $url );
		return $p && 'https' === ( $p['scheme'] ?? '' ) && isset( $p['host'] )
			&& preg_match( '/(^|\.)giphy\.com$/', strtolower( $p['host'] ) );
	}

	/** One GIPHY result as [ mime, size, url, thumb ], or null if unusable. */
	private static function parse( $g ) {
		$id    = is_string( $g['id'] ?? null ) ? $g['id'] : '';
		$clip  = $g['images']['fixed_height']['mp4'] ?? '';
		$size  = (int) ( $g['images']['fixed_height']['mp4_size'] ?? 0 );
		$still = $g['images']['fixed_height_small_still']['url'] ?? ( $g['images']['fixed_height_still']['url'] ?? '' );
		if ( ! preg_match( '/^[A-Za-z0-9]{4,30}$/', $id ) || ! self::giphy_host( $clip ) || ! self::giphy_host( $still )
			|| $size < 1 || $size > self::MAX_BYTES ) {
			return null;
		}
		return array(
			'id'    => $id,
			'mime'  => 'video/mp4',
			'size'  => $size,
			'url'   => $clip,
			'thumb' => $still,
		);
	}

	const DIRECT_DOWN = 'irm_giphy_direct_down';

	/** Which way the last GIPHY request went: direct, gateway or failed. */
	private static $via = '';

	/**
	 * GIPHY's JSON for /v1/gifs{path}, directly or through the gateway.
	 * Values in $args are plain, not URL-encoded.
	 */
	private static function giphy( $path, array $args ) {
		$key = trim( (string) get_option( 'irm_giphy_key', '' ) );
		if ( '' === $key ) {
			return null;
		}
		$args = array_merge( array( 'api_key' => $key ), $args );
		return self::either(
			function () use ( $path, $args ) {
				$res = wp_remote_get(
					add_query_arg( array_map( 'rawurlencode', $args ), 'https://api.giphy.com/v1/gifs' . $path ),
					array( 'timeout' => 8 )
				);
				if ( is_wp_error( $res ) || 200 !== (int) wp_remote_retrieve_response_code( $res ) ) {
					return null;
				}
				$json = json_decode( wp_remote_retrieve_body( $res ), true );
				return is_array( $json ) ? $json : null;
			},
			function () use ( $path, $args ) {
				return IRM_Gateway::call(
					'giphy',
					array(
						'op'   => 'api',
						'path' => $path,
						'args' => $args,
					)
				);
			}
		);
	}

	/** [ data (base64) ] of one file on giphy.com, directly or through the gateway. */
	private static function download( $url ) {
		return self::either(
			function () use ( $url ) {
				$res = wp_remote_get(
					$url,
					array(
						'timeout'             => 10,
						'redirection'         => 2,
						'limit_response_size' => self::MAX_BYTES,
					)
				);
				if ( is_wp_error( $res ) || 200 !== (int) wp_remote_retrieve_response_code( $res ) ) {
					return null;
				}
				return array( 'data' => base64_encode( wp_remote_retrieve_body( $res ) ) );
			},
			function () use ( $url ) {
				$r = IRM_Gateway::call(
					'giphy',
					array(
						'op'  => 'media',
						'url' => $url,
					),
					15
				);
				return is_string( $r['data'] ?? null ) ? $r : null;
			}
		);
	}

	/** Runs $direct, falling back to $relay; remembers a direct failure. */
	private static function either( callable $direct, callable $relay ) {
		if ( ! get_transient( self::DIRECT_DOWN ) ) {
			$out = $direct();
			if ( null !== $out ) {
				self::$via = 'direct';
				return $out;
			}
			set_transient( self::DIRECT_DOWN, 1, 10 * MINUTE_IN_SECONDS );
		}
		$out = $relay();
		if ( null !== $out ) {
			self::$via = 'gateway';
			return $out;
		}
		// Both failed: try the direct way first next time.
		delete_transient( self::DIRECT_DOWN );
		self::$via = 'failed';
		return null;
	}

	/**
	 * GET /gifs/search?q=&offset= — GIPHY search, done by this server so
	 * GIPHY never learns which member searched for what. Results are
	 * cached for an hour; each item is remembered for a day so it can
	 * still be sent after the search.
	 */
	public static function search( WP_REST_Request $request ) {
		$device = IRM_Auth::device();
		if ( ! IRM_Auth::rate_limit( 'gif_search', 200, HOUR_IN_SECONDS, 'd' . $device->id ) ) {
			return new WP_Error( 'irm_rate_limited', 'Too many requests.', array( 'status' => 429 ) );
		}
		$q      = mb_substr( trim( sanitize_text_field( (string) $request->get_param( 'q' ) ) ), 0, 50 );
		$offset = min( 450, max( 0, (int) $request->get_param( 'offset' ) ) );
		if ( '' === $q ) {
			return array( 'items' => array() );
		}
		if ( '' === trim( (string) get_option( 'irm_giphy_key', '' ) ) ) {
			return new WP_Error( 'irm_gif_search_off', 'GIF search is not set up on this server.', array( 'status' => 501 ) );
		}
		$cache = 'irm_gif_q_' . md5( mb_strtolower( $q ) . '|' . $offset );
		$items = get_transient( $cache );
		if ( ! is_array( $items ) ) {
			$json = self::giphy(
				'/search',
				array(
					'q'      => $q,
					'limit'  => self::TREND_SIZE,
					'offset' => $offset,
					'rating' => 'g',
					'lang'   => preg_match( '/\p{Arabic}/u', $q ) ? 'fa' : 'en',
				)
			);
			if ( null === $json ) {
				return new WP_Error( 'irm_gif_unreachable', 'The source did not answer.', array( 'status' => 502 ) );
			}
			$items = array();
			foreach ( (array) ( $json['data'] ?? array() ) as $g ) {
				$item = self::parse( $g );
				if ( $item ) {
					set_transient( 'irm_gif_s_' . $item['id'], $item, DAY_IN_SECONDS );
					$items[] = array(
						'id'   => 's' . $item['id'],
						'mime' => $item['mime'],
						'size' => $item['size'],
						'src'  => 'search',
					);
				}
			}
			set_transient( $cache, $items, HOUR_IN_SECONDS );
		}
		return array( 'items' => $items );
	}

	/** A searched item, from the cache or (after a day) from GIPHY again. */
	private static function searched( $giphy_id ) {
		$item = get_transient( 'irm_gif_s_' . $giphy_id );
		if ( is_array( $item ) ) {
			return $item;
		}
		$json = self::giphy( '/' . rawurlencode( $giphy_id ), array() );
		$item = $json ? self::parse( $json['data'] ?? array() ) : null;
		if ( $item ) {
			set_transient( 'irm_gif_s_' . $giphy_id, $item, DAY_IN_SECONDS );
		}
		return $item;
	}

	/** [ id => [ mime, size, url, thumb ] ], refreshed about once an hour. */
	public static function trending() {
		$key = trim( (string) get_option( 'irm_giphy_key', '' ) );
		if ( '' === $key ) {
			return array();
		}
		$cached = get_transient( 'irm_gif_trend' );
		if ( is_array( $cached ) ) {
			return $cached;
		}
		$json = self::giphy(
			'/trending',
			array(
				'limit'  => self::TREND_SIZE,
				'rating' => 'g',
			)
		);
		$list = array();
		if ( null !== $json ) {
			foreach ( (array) ( $json['data'] ?? array() ) as $g ) {
				$item = self::parse( $g );
				if ( $item ) {
					$list[ 't' . $item['id'] ] = $item;
				}
			}
		}
		update_option(
			'irm_gif_trend_last',
			array(
				'time'   => time(),
				'status' => null === $json ? 0 : 200,
				'count'  => count( $list ),
				'via'    => self::$via,
				'error'  => null === $json ? __( 'GIPHY could not be reached, directly or through the gateway.', 'iran-messenger' ) : '',
			),
			false
		);
		// A failure is remembered for a few minutes so that it is not retried on every request.
		set_transient( 'irm_gif_trend', $list, $list ? HOUR_IN_SECONDS : 5 * MINUTE_IN_SECONDS );
		return $list;
	}

	// ---------------------------------------------------------------
	// REST
	// ---------------------------------------------------------------

	/** GET /gifs */
	public static function index() {
		$items = array();
		foreach ( self::pack() as $id => $g ) {
			$items[] = array(
				'id'   => $id,
				'mime' => $g['mime'],
				'size' => (int) $g['size'],
				'src'  => 'pack',
			);
		}
		foreach ( self::trending() as $id => $g ) {
			$items[] = array(
				'id'   => $id,
				'mime' => $g['mime'],
				'size' => (int) $g['size'],
				'src'  => 'trend',
			);
		}
		return array( 'items' => $items );
	}

	/** GET /gifs/{id}[?thumb=1] — { mime, data (base64) } */
	public static function fetch( WP_REST_Request $request ) {
		$device = IRM_Auth::device();
		if ( ! IRM_Auth::rate_limit( 'gifs', 400, HOUR_IN_SECONDS, 'd' . $device->id ) ) {
			return new WP_Error( 'irm_rate_limited', 'Too many requests.', array( 'status' => 429 ) );
		}
		$id    = (string) $request['id'];
		$thumb = '1' === (string) $request->get_param( 'thumb' );
		$gone  = new WP_Error( 'irm_gif_gone', 'This item is not available.', array( 'status' => 404 ) );

		$pack = self::pack();
		if ( isset( $pack[ $id ] ) ) {
			$bytes = @file_get_contents( self::dir() . '/' . $id ); // phpcs:ignore
			return false === $bytes ? $gone : array(
				'mime' => $pack[ $id ]['mime'],
				'data' => base64_encode( $bytes ),
			);
		}
		if ( 's' === $id[0] ) {
			$item = self::searched( substr( $id, 1 ) );
		} else {
			$trend = self::trending();
			$item  = $trend[ $id ] ?? null;
		}
		if ( ! $item ) {
			return $gone;
		}
		$url = $thumb ? $item['thumb'] : $item['url'];
		if ( ! self::giphy_host( $url ) ) {
			return $gone;
		}
		$file = self::download( $url );
		if ( null === $file ) {
			return new WP_Error( 'irm_gif_unreachable', 'The source did not answer.', array( 'status' => 502 ) );
		}
		return array(
			'mime' => $thumb ? 'image/gif' : $item['mime'],
			'data' => $file['data'],
		);
	}

	// ---------------------------------------------------------------
	// Admin page section
	// ---------------------------------------------------------------

	/** Handles this section's form posts. Returns a notice or ''. */
	public static function handle( $action ) {
		if ( 'gif_add' === $action ) {
			$added  = 0;
			$error  = '';
			$files  = $_FILES['gifs'] ?? null; // phpcs:ignore
			$count  = is_array( $files['name'] ?? null ) ? count( $files['name'] ) : 0;
			for ( $i = 0; $i < $count; $i++ ) {
				$e = self::add_upload(
					array(
						'name'     => $files['name'][ $i ],
						'tmp_name' => $files['tmp_name'][ $i ],
					)
				);
				if ( '' === $e ) {
					++$added;
				} else {
					$error = $e;
				}
			}
			/* translators: %d: number of files */
			return trim( sprintf( __( '%d file(s) added.', 'iran-messenger' ), $added ) . ' ' . $error );
		}
		if ( 'gif_remove' === $action && isset( $_POST['gif_id'] ) ) { // phpcs:ignore
			self::remove( sanitize_key( wp_unslash( $_POST['gif_id'] ) ) ); // phpcs:ignore
			return __( 'Removed.', 'iran-messenger' );
		}
		if ( 'gif_key' === $action ) {
			$key = isset( $_POST['giphy_key'] ) ? sanitize_text_field( wp_unslash( $_POST['giphy_key'] ) ) : ''; // phpcs:ignore
			update_option( 'irm_giphy_key', preg_replace( '/[^A-Za-z0-9]/', '', $key ), false );
			delete_transient( 'irm_gif_trend' );
			self::trending();
			return __( 'Saved.', 'iran-messenger' );
		}
		return '';
	}

	public static function render() {
		$pack = self::pack();
		?>
		<h2><?php esc_html_e( 'GIF collection', 'iran-messenger' ); ?></h2>
		<p class="description"><?php esc_html_e( 'Members see these in the app under "Suggested". GIF, WebP or MP4, up to 3 MB each.', 'iran-messenger' ); ?></p>
		<form method="post" enctype="multipart/form-data">
			<?php wp_nonce_field( 'irm_admin' ); ?>
			<input type="hidden" name="irm_action" value="gif_add">
			<input type="file" name="gifs[]" multiple accept=".gif,.webp,.mp4">
			<?php submit_button( __( 'Add files', 'iran-messenger' ), 'secondary', 'submit', false ); ?>
		</form>
		<?php if ( $pack ) : ?>
			<table class="widefat striped" style="max-width:640px;margin-top:10px">
				<tbody>
				<?php foreach ( $pack as $id => $g ) : ?>
					<tr>
						<td><?php echo esc_html( $g['name'] ); ?></td>
						<td><?php echo esc_html( size_format( (int) $g['size'] ) ); ?></td>
						<td>
							<form method="post">
								<?php wp_nonce_field( 'irm_admin' ); ?>
								<input type="hidden" name="gif_id" value="<?php echo esc_attr( $id ); ?>">
								<button class="button button-small" name="irm_action" value="gif_remove"><?php esc_html_e( 'Remove', 'iran-messenger' ); ?></button>
							</form>
						</td>
					</tr>
				<?php endforeach; ?>
				</tbody>
			</table>
		<?php endif; ?>

		<h3><?php esc_html_e( 'Popular GIFs from the internet', 'iran-messenger' ); ?></h3>
		<p class="description"><?php esc_html_e( 'Optional. With a GIPHY API key, this server fetches the currently popular GIFs and passes them on to members; members never contact GIPHY themselves. Leave empty to turn it off.', 'iran-messenger' ); ?></p>
		<form method="post">
			<?php wp_nonce_field( 'irm_admin' ); ?>
			<input type="hidden" name="irm_action" value="gif_key">
			<input type="text" name="giphy_key" class="regular-text code" autocomplete="off" value="<?php echo esc_attr( (string) get_option( 'irm_giphy_key', '' ) ); ?>" placeholder="GIPHY API key">
			<?php submit_button( __( 'Save', 'iran-messenger' ), 'secondary', 'submit', false ); ?>
		</form>
		<?php
		$last = get_option( 'irm_gif_trend_last' );
		if ( is_array( $last ) && '' !== (string) get_option( 'irm_giphy_key', '' ) ) {
			echo '<p>' . esc_html(
				sprintf(
					/* translators: 1: time, 2: result */
					__( 'Last fetch: %1$s — %2$s', 'iran-messenger' ),
					wp_date( 'Y-m-d H:i:s', (int) $last['time'] ),
					200 === (int) $last['status']
						/* translators: %d: number of items */
						? sprintf( __( '%d items', 'iran-messenger' ), (int) $last['count'] )
							. ( 'gateway' === ( $last['via'] ?? '' ) ? ' ' . __( '(through the gateway; this server cannot reach GIPHY directly)', 'iran-messenger' ) : '' )
						: ( $last['status'] ? 'HTTP ' . $last['status'] : $last['error'] )
				)
			) . '</p>';
		}
	}
}
