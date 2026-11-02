<?php
/**
 * Plugin Name:       IRAN Messenger Relay
 * Description:       Forwards IRAN Messenger requests to one fixed messenger server, for members who cannot reach it directly. Carries only end-to-end encrypted, signed traffic and is not an open proxy.
 * Version:           1.0.0
 * Requires at least: 6.2
 * Requires PHP:      7.4
 * License:           GPL-3.0-or-later
 * Text Domain:       iran-messenger-relay
 */

defined( 'ABSPATH' ) || exit;

/**
 * What this site's owner agrees to by enabling it:
 *  - Requests are passed to ONE address chosen here, never to an address
 *    supplied by the caller.
 *  - Only callers that know this site's access key are served; everyone
 *    else gets the same 404 as any unknown address.
 *  - The relay cannot read messages (they are end-to-end encrypted) and
 *    cannot forge answers (the messenger server signs them). It does see
 *    the caller's IP address, timing and sizes.
 *  - Nothing is stored except a daily request counter.
 *  - Browsers may call it only from the messenger server's own address
 *    (its web app); every other site is refused.
 */
class Irm_Relay {

	const NS          = 'pr/v1';
	const MAX_BODY    = 1048576;
	// Answers can be larger than requests: a GIF of up to 3 MB arrives as
	// base64 inside JSON.
	const MAX_ANSWER  = 6291456;
	const VERSION     = '1.0.0';
	const DAILY_LIMIT = 200000;

	public static function init() {
		add_action( 'rest_api_init', array( __CLASS__, 'routes' ) );
		add_filter( 'rest_index', array( __CLASS__, 'hide_from_index' ) );
		add_filter( 'rest_pre_dispatch', array( __CLASS__, 'preflight' ), 5, 3 );
		add_filter( 'rest_allowed_cors_headers', array( __CLASS__, 'cors_headers' ), 10, 2 );
		add_action( 'admin_menu', array( __CLASS__, 'menu' ) );
	}

	private static function settings() {
		return wp_parse_args(
			(array) get_option( 'irm_relay', array() ),
			array(
				'enabled'  => 0,
				'upstream' => '',
				'key'      => '',
			)
		);
	}

	public static function routes() {
		register_rest_route(
			self::NS,
			'/f/(?P<path>[a-z0-9/_-]{1,120})',
			array(
				'methods'             => array( 'GET', 'POST' ),
				'callback'            => array( __CLASS__, 'forward' ),
				'permission_callback' => array( __CLASS__, 'allowed' ),
			)
		);
	}

	/** Do not advertise the relay in the site's public REST index. */
	public static function hide_from_index( $response ) {
		$data = $response->get_data();
		if ( isset( $data['namespaces'] ) ) {
			$data['namespaces'] = array_values( array_diff( $data['namespaces'], array( self::NS ) ) );
		}
		if ( isset( $data['routes'] ) ) {
			foreach ( array_keys( $data['routes'] ) as $route ) {
				if ( 0 === strpos( $route, '/' . self::NS ) ) {
					unset( $data['routes'][ $route ] );
				}
			}
		}
		$response->set_data( $data );
		return $response;
	}

	private static function ours( WP_REST_Request $request ) {
		return 0 === strpos( $request->get_route(), '/' . self::NS . '/' );
	}

	/** host[:port] without a leading "www.", for comparing addresses. */
	private static function site_of( $url ) {
		$p = wp_parse_url( (string) $url );
		if ( ! $p || empty( $p['host'] ) ) {
			return '';
		}
		$host = preg_replace( '/^www\./', '', strtolower( $p['host'] ) );
		return isset( $p['port'] ) ? $host . ':' . (int) $p['port'] : $host;
	}

	/** The browser's Origin, if it is the messenger server's web app. */
	private static function app_origin() {
		$origin = get_http_origin();
		$s      = self::settings();
		if ( ! $origin || '' === $s['upstream'] || self::site_of( $origin ) !== self::site_of( $s['upstream'] ) ) {
			return '';
		}
		return $origin;
	}

	/**
	 * A browser asks first whether it may send the messenger's headers.
	 * Only the messenger's own web app gets a yes; for anyone else the
	 * relay does not exist.
	 */
	public static function preflight( $result, $server, $request ) {
		if ( 'OPTIONS' !== $request->get_method() || ! self::ours( $request ) ) {
			return $result;
		}
		if ( ! self::settings()['enabled'] || '' === self::app_origin() ) {
			return new WP_Error( 'rest_no_route', 'No route was found matching the URL and request method.', array( 'status' => 404 ) );
		}
		$response = new WP_REST_Response( null, 204 );
		$response->header( 'Access-Control-Max-Age', '600' );
		return $response;
	}

	public static function cors_headers( $headers, $request = null ) {
		// Named only to the messenger's web app, so nobody else learns the
		// relay is here.
		if ( $request instanceof WP_REST_Request && self::ours( $request ) && self::settings()['enabled'] && '' !== self::app_origin() ) {
			$headers = array_merge( $headers, array( 'X-IRM-Device', 'X-IRM-Time', 'X-IRM-Nonce', 'X-IRM-Sig', 'X-Relay-Key' ) );
		}
		return $headers;
	}

	public static function allowed( WP_REST_Request $request ) {
		$s     = self::settings();
		$given = (string) $request->get_header( 'x_relay_key' );
		// Same answer for "disabled", "no key" and "wrong key".
		if ( ! $s['enabled'] || '' === $s['key'] || '' === $s['upstream'] || ! hash_equals( $s['key'], $given ) ) {
			return new WP_Error( 'rest_no_route', 'No route was found matching the URL and request method.', array( 'status' => 404 ) );
		}
		return true;
	}

	private static function fail( $status, $code ) {
		return new WP_Error( $code, 'Relay could not complete the request.', array( 'status' => $status ) );
	}

	public static function forward( WP_REST_Request $request ) {
		$s    = self::settings();
		$body = (string) $request->get_body();
		if ( strlen( $body ) > self::MAX_BODY ) {
			return self::fail( 413, 'relay_too_large' );
		}

		$day   = 'irm_relay_n_' . gmdate( 'Ymd' );
		$count = (int) get_transient( $day );
		if ( $count >= self::DAILY_LIMIT ) {
			return self::fail( 429, 'relay_quota' );
		}
		set_transient( $day, $count + 1, DAY_IN_SECONDS );

		// The destination host is fixed by the site owner. Only the path
		// below the messenger API and plain query values come from the caller.
		$query = $request->get_query_params();
		unset( $query['rest_route'] );
		ksort( $query, SORT_STRING );
		$pairs = array();
		foreach ( $query as $k => $v ) {
			if ( is_scalar( $v ) ) {
				$pairs[] = rawurlencode( (string) $k ) . '=' . rawurlencode( (string) $v );
			}
		}
		$url = untrailingslashit( $s['upstream'] ) . '/wp-json/irm/v1/' . $request['path'];
		if ( $pairs ) {
			$url .= '?' . implode( '&', $pairs );
		}

		$headers = array( 'Accept' => 'application/json' );
		foreach ( array( 'content_type' => 'Content-Type', 'x_irm_device' => 'X-IRM-Device', 'x_irm_time' => 'X-IRM-Time', 'x_irm_nonce' => 'X-IRM-Nonce', 'x_irm_sig' => 'X-IRM-Sig' ) as $in => $out ) {
			$value = $request->get_header( $in );
			if ( null !== $value && strlen( $value ) <= 200 ) {
				$headers[ $out ] = $value;
			}
		}

		$response = wp_remote_request(
			$url,
			array(
				'method'              => $request->get_method(),
				'headers'             => $headers,
				'body'                => 'POST' === $request->get_method() ? $body : null,
				'timeout'             => 25,
				'redirection'         => 0,
				'limit_response_size' => self::MAX_ANSWER + 1,
				'user-agent'          => 'IrmRelay/' . self::VERSION,
			)
		);
		if ( is_wp_error( $response ) ) {
			return self::fail( 502, 'relay_upstream' );
		}

		$answer = wp_remote_retrieve_body( $response );
		if ( strlen( $answer ) > self::MAX_ANSWER ) {
			// A cut answer would look like a firewall page to the app.
			return self::fail( 502, 'relay_answer_too_large' );
		}

		// Written byte-for-byte: the messenger server's signature covers the
		// exact body, so it must not be re-encoded here.
		status_header( (int) wp_remote_retrieve_response_code( $response ) );
		header( 'Content-Type: application/json; charset=UTF-8' );
		header( 'Cache-Control: no-store, private, max-age=0' );
		// This answer ends the request here, before WordPress would add its
		// own cross-site headers, so the web app's are set directly.
		$origin = self::app_origin();
		if ( '' !== $origin ) {
			header( 'Access-Control-Allow-Origin: ' . esc_url_raw( $origin ) );
			header( 'Access-Control-Expose-Headers: X-IRM-Server-Sig' );
			header( 'Vary: Origin' );
		}
		$sig = wp_remote_retrieve_header( $response, 'x-irm-server-sig' );
		if ( is_string( $sig ) && '' !== $sig ) {
			header( 'X-IRM-Server-Sig: ' . preg_replace( '/[^A-Za-z0-9+\/=]/', '', $sig ) );
		}
		echo $answer; // phpcs:ignore WordPress.Security.EscapeOutput
		exit;
	}

	public static function menu() {
		add_options_page( 'IRAN Messenger Relay', 'IRAN Messenger Relay', 'manage_options', 'iran-messenger-relay', array( __CLASS__, 'page' ) );
	}

	public static function page() {
		if ( ! current_user_can( 'manage_options' ) ) {
			return;
		}
		$s = self::settings();
		if ( isset( $_POST['irm_relay_save'] ) ) {
			check_admin_referer( 'irm_relay' );
			$upstream = isset( $_POST['upstream'] ) ? untrailingslashit( esc_url_raw( wp_unslash( $_POST['upstream'] ), array( 'https', 'http' ) ) ) : '';
			// Refuses private and loopback targets unless a developer allows them.
			if ( '' !== $upstream && ! wp_http_validate_url( $upstream ) && ! ( defined( 'IRM_RELAY_ALLOW_LOCAL' ) && IRM_RELAY_ALLOW_LOCAL ) ) {
				$upstream = '';
			}
			$s['upstream'] = $upstream;
			$s['enabled']  = empty( $_POST['enabled'] ) ? 0 : 1;
			if ( '' === $s['key'] || ! empty( $_POST['new_key'] ) ) {
				$s['key'] = rtrim( strtr( base64_encode( random_bytes( 24 ) ), '+/', '-_' ), '=' );
			}
			update_option( 'irm_relay', $s, false );
			echo '<div class="notice notice-success"><p>' . esc_html__( 'Saved.', 'iran-messenger-relay' ) . '</p></div>';
		}
		$today = (int) get_transient( 'irm_relay_n_' . gmdate( 'Ymd' ) );
		?>
		<div class="wrap">
			<h1>IRAN Messenger Relay</h1>
			<p><?php esc_html_e( 'This site passes encrypted IRAN Messenger traffic to the one server below. It cannot read messages. It does see callers\' IP addresses and timing, and this site becomes identifiable as a relay to anyone who holds the access key.', 'iran-messenger-relay' ); ?></p>
			<form method="post">
				<?php wp_nonce_field( 'irm_relay' ); ?>
				<table class="form-table">
					<tr>
						<th><?php esc_html_e( 'Messenger server address', 'iran-messenger-relay' ); ?></th>
						<td><input type="url" name="upstream" class="regular-text" value="<?php echo esc_attr( $s['upstream'] ); ?>" placeholder="https://example.ir"></td>
					</tr>
					<tr>
						<th><?php esc_html_e( 'Relay enabled', 'iran-messenger-relay' ); ?></th>
						<td><label><input type="checkbox" name="enabled" value="1" <?php checked( (int) $s['enabled'], 1 ); ?>> <?php esc_html_e( 'Forward requests', 'iran-messenger-relay' ); ?></label></td>
					</tr>
					<tr>
						<th><?php esc_html_e( 'Access key', 'iran-messenger-relay' ); ?></th>
						<td>
							<code><?php echo esc_html( $s['key'] ? $s['key'] : '—' ); ?></code>
							<p class="description"><?php esc_html_e( 'Give this key and this site\'s address only to the messenger server\'s administrator.', 'iran-messenger-relay' ); ?></p>
							<label><input type="checkbox" name="new_key" value="1"> <?php esc_html_e( 'Generate a new key (the old one stops working)', 'iran-messenger-relay' ); ?></label>
						</td>
					</tr>
					<tr>
						<th><?php esc_html_e( 'Requests today', 'iran-messenger-relay' ); ?></th>
						<td><?php echo (int) $today; ?> / <?php echo (int) self::DAILY_LIMIT; ?></td>
					</tr>
				</table>
				<?php submit_button( __( 'Save', 'iran-messenger-relay' ), 'primary', 'irm_relay_save' ); ?>
			</form>
		</div>
		<?php
	}
}

Irm_Relay::init();
