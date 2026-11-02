<?php
defined( 'ABSPATH' ) || exit;

/** Route table for /wp-json/irm/v1. */
class IRM_Rest {

	public static function register_routes() {
		$signed = array( 'IRM_Auth', 'require_device' );

		// Public by design: these are how a device obtains its identity.
		foreach ( array( 'register', 'login' ) as $action ) {
			register_rest_route(
				IRM_REST_NS,
				'/auth/' . $action,
				array(
					'methods'             => 'POST',
					'callback'            => array( 'IRM_Accounts', $action ),
					'permission_callback' => '__return_true',
				)
			);
		}

		$routes = array(
			array( '/me', 'GET', array( 'IRM_Accounts', 'me' ) ),
			array( '/me/username', 'POST', array( 'IRM_Discovery', 'set_username' ) ),
			array( '/me/profile', 'POST', array( 'IRM_Accounts', 'profile' ) ),
			array( '/me/password', 'POST', array( 'IRM_Accounts', 'password' ) ),
			array( '/config', 'GET', array( 'IRM_Discovery', 'config' ) ),
			array( '/push/subscribe', 'POST', array( 'IRM_Push', 'subscribe' ) ),
			array( '/push/unsubscribe', 'POST', array( 'IRM_Push', 'unsubscribe' ) ),
			array( '/push/idle', 'POST', array( 'IRM_Push', 'idle' ) ),
			array( '/push/fcm', 'POST', array( 'IRM_Gateway', 'register' ) ),
			array( '/gifs', 'GET', array( 'IRM_Gifs', 'index' ) ),
			// Before the item route, which would otherwise take "search" as an id.
			array( '/gifs/search', 'GET', array( 'IRM_Gifs', 'search' ) ),
			array( '/gifs/(?P<id>[A-Za-z0-9]{5,40})', 'GET', array( 'IRM_Gifs', 'fetch' ) ),
			array( '/contacts/match', 'POST', array( 'IRM_Discovery', 'match' ) ),
			array( '/users/lookup', 'GET', array( 'IRM_Discovery', 'lookup' ) ),
			array( '/caps', 'POST', array( 'IRM_Discovery', 'caps' ) ),
			array( '/keys/prekeys', 'POST', array( 'IRM_Keys', 'upload_prekeys' ) ),
			array( '/keys/(?P<identity_id>\d+)', 'GET', array( 'IRM_Keys', 'bundles' ) ),
			array( '/envelopes', 'POST', array( 'IRM_Messages', 'send' ) ),
			array( '/sync', 'GET', array( 'IRM_Messages', 'sync' ) ),
			array( '/receipts', 'POST', array( 'IRM_Messages', 'ack' ) ),
			array( '/media/uploads', 'POST', array( 'IRM_Media', 'start' ) ),
			array( '/media/uploads/(?P<media_id>[a-f0-9]{32})', 'GET', array( 'IRM_Media', 'status' ) ),
			array( '/media/uploads/(?P<media_id>[a-f0-9]{32})/chunks', 'POST', array( 'IRM_Media', 'chunk' ) ),
			array( '/media/(?P<media_id>[a-f0-9]{32})', 'GET', array( 'IRM_Media', 'download' ) ),
			array( '/media/(?P<media_id>[a-f0-9]{32})/done', 'POST', array( 'IRM_Media', 'done' ) ),
			array( '/media/(?P<media_id>[a-f0-9]{32})/delete', 'POST', array( 'IRM_Media', 'take_back' ) ),
		);
		foreach ( $routes as $r ) {
			register_rest_route(
				IRM_REST_NS,
				$r[0],
				array(
					'methods'             => $r[1],
					'callback'            => $r[2],
					'permission_callback' => $signed,
				)
			);
		}

		add_filter( 'rest_post_dispatch', array( __CLASS__, 'no_cache' ), 10, 3 );
	}

	/** Private responses must never be stored by a page cache or CDN. */
	public static function no_cache( $response, $server, $request ) {
		if ( 0 === strpos( $request->get_route(), '/' . IRM_REST_NS ) && $response instanceof WP_HTTP_Response ) {
			$response->header( 'Cache-Control', 'no-store, private, max-age=0' );
			$response->header( 'Pragma', 'no-cache' );
		}
		return $response;
	}
}
