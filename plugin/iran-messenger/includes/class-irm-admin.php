<?php
defined( 'ABSPATH' ) || exit;

/**
 * Admin screen: invites, members and devices. Shows routing metadata only;
 * there is no way to read message content from here or from the database.
 */
class IRM_Admin {

	public static function menu() {
		add_menu_page(
			__( 'IRAN Messenger', 'iran-messenger' ),
			__( 'IRAN Messenger', 'iran-messenger' ),
			'manage_options',
			'irm',
			array( __CLASS__, 'page' ),
			'dashicons-lock'
		);
	}

	public static function page() {
		global $wpdb;
		if ( ! current_user_can( 'manage_options' ) ) {
			return;
		}

		$new_token = '';
		$notice    = '';
		if ( isset( $_POST['irm_action'] ) ) {
			check_admin_referer( 'irm_admin' );
			$action = sanitize_key( wp_unslash( $_POST['irm_action'] ) );
			if ( 0 === strpos( $action, 'gif_' ) ) {
				$notice = IRM_Gifs::handle( $action );
			} elseif ( 'invite' === $action ) {
				$note      = isset( $_POST['note'] ) ? mb_substr( sanitize_text_field( wp_unslash( $_POST['note'] ) ), 0, 80 ) : '';
				$new_token = IRM_Accounts::create_invite( $note );
			} elseif ( 'gateway' === $action ) {
				IRM_Gateway::save(
					isset( $_POST['gateway_url'] ) ? sanitize_text_field( wp_unslash( $_POST['gateway_url'] ) ) : '',
					isset( $_POST['gateway_key'] ) ? sanitize_text_field( wp_unslash( $_POST['gateway_key'] ) ) : ''
				);
				$notice = __( 'Gateway saved.', 'iran-messenger' );
			} elseif ( 'gateway_test' === $action ) {
				$notice = IRM_Gateway::test();
			} elseif ( in_array( $action, array( 'bot_on', 'bot_off' ), true ) && isset( $_POST['identity_id'] ) ) {
				$wpdb->update(
					IRM_Schema::table( 'identities' ),
					array( 'is_bot' => 'bot_on' === $action ? 1 : 0 ),
					array( 'id' => absint( $_POST['identity_id'] ) )
				);
				$notice = 'bot_on' === $action
					? __( 'Marked as a bot. Members\' apps no longer send it any chat content; it can only post.', 'iran-messenger' )
					: __( 'No longer a bot.', 'iran-messenger' );
			} elseif ( 'relays' === $action ) {
				IRM_Signing::save_relays( isset( $_POST['relays'] ) ? sanitize_textarea_field( wp_unslash( $_POST['relays'] ) ) : '' );
				$notice = __( 'Relay list saved.', 'iran-messenger' );
			} elseif ( 'open_registration' === $action ) {
				update_option( 'irm_open_registration', empty( $_POST['open'] ) ? 0 : 1, false );
				$notice = __( 'Saved.', 'iran-messenger' );
			} elseif ( in_array( $action, array( 'approve', 'reject', 'disable' ), true ) && isset( $_POST['identity_id'] ) ) {
				$id     = absint( $_POST['identity_id'] );
				$active = (int) $wpdb->get_var( 'SELECT COUNT(*) FROM ' . IRM_Schema::table( 'identities' ) . " WHERE status = 'active' AND is_bot = 0" );
				if ( 'approve' === $action && $active >= IRM_MAX_MEMBERS ) {
					$notice = __( 'Member limit reached; nobody was approved.', 'iran-messenger' );
				} else {
					$wpdb->update(
						IRM_Schema::table( 'identities' ),
						array( 'status' => 'approve' === $action ? 'active' : ( 'reject' === $action ? 'rejected' : 'disabled' ) ),
						array( 'id' => $id )
					);
					if ( 'approve' !== $action ) {
						$wpdb->update(
							IRM_Schema::table( 'devices' ),
							array(
								'status'     => 'revoked',
								'revoked_at' => time(),
							),
							array( 'identity_id' => $id )
						);
					}
					$notice = __( 'Done.', 'iran-messenger' );
				}
			} elseif ( 'revoke_device' === $action && isset( $_POST['device_id'] ) ) {
				$wpdb->update(
					IRM_Schema::table( 'devices' ),
					array(
						'status'     => 'revoked',
						'revoked_at' => time(),
					),
					array( 'id' => absint( $_POST['device_id'] ) )
				);
				$notice = __( 'Device revoked. Data it already downloaded stays on that device.', 'iran-messenger' );
			}
		}

		$now     = time();
		$invites = $wpdb->get_results( 'SELECT * FROM ' . IRM_Schema::table( 'invites' ) . ' ORDER BY id DESC LIMIT 30' );
		$devices = $wpdb->get_results(
			'SELECT d.*, i.display_name, i.username FROM ' . IRM_Schema::table( 'devices' ) . ' d
			 JOIN ' . IRM_Schema::table( 'identities' ) . ' i ON i.id = d.identity_id ORDER BY d.id'
		);
		$waiting = $wpdb->get_results(
			'SELECT id, username, created_at FROM ' . IRM_Schema::table( 'identities' ) . " WHERE status = 'pending' ORDER BY id"
		);
		$members = $wpdb->get_results(
			'SELECT id, username, display_name, created_at, is_bot FROM ' . IRM_Schema::table( 'identities' ) . " WHERE status = 'active' ORDER BY id"
		);
		$pending = (int) $wpdb->get_var(
			$wpdb->prepare( 'SELECT COUNT(*) FROM ' . IRM_Schema::table( 'deliveries' ) . ' WHERE acked_at = 0 AND expires_at > %d', $now )
		);
		?>
		<div class="wrap">
			<h1><?php esc_html_e( 'IRAN Messenger', 'iran-messenger' ); ?></h1>
			<p>
				<?php
				printf(
					/* translators: 1: version, 2: member limit, 3: undelivered envelope count */
					esc_html__( 'Version %1$s · member limit %2$d · envelopes waiting for delivery: %3$d', 'iran-messenger' ),
					esc_html( IRM_VERSION ),
					(int) IRM_MAX_MEMBERS,
					(int) $pending
				);
				?>
			</p>
			<?php if ( $notice ) : ?>
				<div class="notice notice-success"><p><?php echo esc_html( $notice ); ?></p></div>
			<?php endif; ?>

			<?php if ( $new_token ) : ?>
				<div class="notice notice-warning">
					<p><strong><?php esc_html_e( 'New invite code — shown only once. Whoever registers with it is approved automatically.', 'iran-messenger' ); ?></strong></p>
					<p style="font-size:22px;letter-spacing:2px"><code><?php echo esc_html( $new_token ); ?></code></p>
				</div>
			<?php endif; ?>

			<h2><?php esc_html_e( 'Waiting for approval', 'iran-messenger' ); ?> (<?php echo count( $waiting ); ?>)</h2>
			<?php if ( ! $waiting ) : ?>
				<p><?php esc_html_e( 'Nobody is waiting.', 'iran-messenger' ); ?></p>
			<?php else : ?>
			<table class="widefat striped">
				<tbody>
				<?php foreach ( $waiting as $w ) : ?>
					<tr>
						<td><strong>@<?php echo esc_html( $w->username ); ?></strong></td>
						<td><?php echo esc_html( wp_date( 'Y-m-d H:i', (int) $w->created_at ) ); ?></td>
						<td>
							<form method="post" style="display:inline">
								<?php wp_nonce_field( 'irm_admin' ); ?>
								<input type="hidden" name="identity_id" value="<?php echo (int) $w->id; ?>">
								<button class="button button-primary" name="irm_action" value="approve"><?php esc_html_e( 'Approve', 'iran-messenger' ); ?></button>
								<button class="button" name="irm_action" value="reject"><?php esc_html_e( 'Reject', 'iran-messenger' ); ?></button>
							</form>
						</td>
					</tr>
				<?php endforeach; ?>
				</tbody>
			</table>
			<?php endif; ?>

			<form method="post" style="margin-top:12px">
				<?php wp_nonce_field( 'irm_admin' ); ?>
				<input type="hidden" name="irm_action" value="open_registration">
				<label>
					<input type="checkbox" name="open" value="1" <?php checked( (int) get_option( 'irm_open_registration', 1 ), 1 ); ?>>
					<?php esc_html_e( 'Allow registration without an invite code (each request waits here for approval)', 'iran-messenger' ); ?>
				</label>
				<?php submit_button( __( 'Save', 'iran-messenger' ), 'secondary small', 'submit', false ); ?>
			</form>

			<h2><?php esc_html_e( 'Members', 'iran-messenger' ); ?> (<?php echo count( $members ); ?> / <?php echo (int) IRM_MAX_MEMBERS; ?>)</h2>
			<table class="widefat striped">
				<tbody>
				<?php foreach ( $members as $mb ) : ?>
					<tr>
						<td><strong>@<?php echo esc_html( (string) $mb->username ); ?></strong></td>
						<td><?php echo esc_html( $mb->display_name ); ?><?php echo $mb->is_bot ? ' <span class="dashicons dashicons-admin-generic" title="bot"></span> ' . esc_html__( '(bot)', 'iran-messenger' ) : ''; ?></td>
						<td>
							<form method="post" style="display:inline">
								<?php wp_nonce_field( 'irm_admin' ); ?>
								<input type="hidden" name="identity_id" value="<?php echo (int) $mb->id; ?>">
								<button class="button button-small" name="irm_action" value="<?php echo $mb->is_bot ? 'bot_off' : 'bot_on'; ?>"><?php echo $mb->is_bot ? esc_html__( 'Not a bot', 'iran-messenger' ) : esc_html__( 'Make bot', 'iran-messenger' ); ?></button>
							</form>
							<form method="post" style="display:inline" onsubmit="return confirm('<?php echo esc_js( __( 'Disable this member?', 'iran-messenger' ) ); ?>')">
								<?php wp_nonce_field( 'irm_admin' ); ?>
								<input type="hidden" name="identity_id" value="<?php echo (int) $mb->id; ?>">
								<button class="button button-small" name="irm_action" value="disable"><?php esc_html_e( 'Disable', 'iran-messenger' ); ?></button>
							</form>
						</td>
					</tr>
				<?php endforeach; ?>
				</tbody>
			</table>

			<h2><?php esc_html_e( 'Create invite code', 'iran-messenger' ); ?></h2>
			<form method="post">
				<?php wp_nonce_field( 'irm_admin' ); ?>
				<input type="hidden" name="irm_action" value="invite">
				<input type="text" name="note" maxlength="80" class="regular-text" placeholder="<?php esc_attr_e( 'Note (who is it for?)', 'iran-messenger' ); ?>">
				<?php submit_button( __( 'Create single-use invite code', 'iran-messenger' ), 'primary', 'submit', false ); ?>
			</form>

			<h2><?php esc_html_e( 'Private relays', 'iran-messenger' ); ?></h2>
			<p><?php esc_html_e( 'Other sites running the IRAN Messenger Relay plugin that members can go through when this server is not reachable directly. One per line: address|access key. The list is sent only to approved members.', 'iran-messenger' ); ?></p>
			<form method="post">
				<?php wp_nonce_field( 'irm_admin' ); ?>
				<input type="hidden" name="irm_action" value="relays">
				<textarea name="relays" rows="4" class="large-text code" placeholder="https://friend-site.ir|access-key"><?php
				foreach ( IRM_Signing::relays() as $r ) {
					echo esc_textarea( $r['url'] . '|' . $r['key'] . "\n" );
				}
				?></textarea>
				<?php submit_button( __( 'Save relays', 'iran-messenger' ), 'secondary', 'submit', false ); ?>
			</form>
			<p class="description"><?php esc_html_e( 'Server signing key (public):', 'iran-messenger' ); ?> <code><?php echo esc_html( IRM_Signing::public_key() ); ?></code></p>

			<h2><?php esc_html_e( 'Web app (iPhone and browsers)', 'iran-messenger' ); ?></h2>
			<?php self::web_app_status(); ?>

			<h2><?php esc_html_e( 'Instant alerts on Android (push gateway gateway)', 'iran-messenger' ); ?></h2>
			<?php self::gateway_status(); ?>

			<?php IRM_Gifs::render(); ?>

			<h2><?php esc_html_e( 'Invites', 'iran-messenger' ); ?></h2>
			<table class="widefat striped">
				<thead><tr>
					<th>#</th>
					<th><?php esc_html_e( 'Note', 'iran-messenger' ); ?></th>
					<th><?php esc_html_e( 'Created', 'iran-messenger' ); ?></th>
					<th><?php esc_html_e( 'Status', 'iran-messenger' ); ?></th>
				</tr></thead>
				<tbody>
				<?php foreach ( $invites as $inv ) : ?>
					<tr>
						<td><?php echo (int) $inv->id; ?></td>
						<td><?php echo esc_html( $inv->note ); ?></td>
						<td><?php echo esc_html( wp_date( 'Y-m-d H:i', (int) $inv->created_at ) ); ?></td>
						<td>
							<?php
							if ( $inv->used_at ) {
								esc_html_e( 'Used', 'iran-messenger' );
							} elseif ( $inv->expires_at < $now ) {
								esc_html_e( 'Expired', 'iran-messenger' );
							} else {
								esc_html_e( 'Waiting', 'iran-messenger' );
							}
							?>
						</td>
					</tr>
				<?php endforeach; ?>
				</tbody>
			</table>

			<h2><?php esc_html_e( 'Devices', 'iran-messenger' ); ?></h2>
			<table class="widefat striped">
				<thead><tr>
					<th>#</th>
					<th><?php esc_html_e( 'Member', 'iran-messenger' ); ?></th>
					<th><?php esc_html_e( 'Role', 'iran-messenger' ); ?></th>
					<th><?php esc_html_e( 'Last seen', 'iran-messenger' ); ?></th>
					<th><?php esc_html_e( 'Status', 'iran-messenger' ); ?></th>
					<th></th>
				</tr></thead>
				<tbody>
				<?php foreach ( $devices as $d ) : ?>
					<tr>
						<td><?php echo (int) $d->id; ?></td>
						<td><?php echo esc_html( $d->display_name . ( $d->username ? ' (@' . $d->username . ')' : '' ) ); ?></td>
						<td><?php echo esc_html( $d->role ); ?></td>
						<td><?php echo $d->last_seen_at ? esc_html( wp_date( 'Y-m-d H:i', (int) $d->last_seen_at ) ) : '—'; ?></td>
						<td><?php echo esc_html( $d->status ); ?></td>
						<td>
							<?php if ( 'active' === $d->status ) : ?>
								<form method="post">
									<?php wp_nonce_field( 'irm_admin' ); ?>
									<input type="hidden" name="irm_action" value="revoke_device">
									<input type="hidden" name="device_id" value="<?php echo (int) $d->id; ?>">
									<?php submit_button( __( 'Revoke', 'iran-messenger' ), 'delete small', 'submit', false ); ?>
								</form>
							<?php endif; ?>
						</td>
					</tr>
				<?php endforeach; ?>
				</tbody>
			</table>
		</div>
		<?php
	}

	/** Settings and last result of the push gateway gateway. */
	private static function gateway_status() {
		global $wpdb;
		$g      = IRM_Gateway::settings();
		$phones = (int) $wpdb->get_var( 'SELECT COUNT(*) FROM ' . IRM_Schema::table( 'fcm' ) );
		echo '<p>' . esc_html__( 'A site outside Iran running the push gateway plugin wakes phones through Google the moment a message arrives. Only push tokens are sent to it, never messages.', 'iran-messenger' ) . '</p>';
		?>
		<form method="post">
			<?php wp_nonce_field( 'irm_admin' ); ?>
			<input type="hidden" name="irm_action" value="gateway">
			<p><input type="url" name="gateway_url" class="large-text code" value="<?php echo esc_attr( $g['url'] ); ?>" placeholder="https://example.de/wp-json/pp/v1/wake"></p>
			<p><input type="text" name="gateway_key" class="large-text code" value="<?php echo esc_attr( $g['key'] ); ?>" autocomplete="off" placeholder="<?php esc_attr_e( 'Access key from the push gateway settings page', 'iran-messenger' ); ?>"></p>
			<?php submit_button( __( 'Save gateway', 'iran-messenger' ), 'secondary', 'submit', false ); ?>
		</form>
		<?php
		echo '<p>' . esc_html( sprintf( /* translators: %d: number of phones */ __( 'Phones registered for instant alerts: %d', 'iran-messenger' ), $phones ) ) . '</p>';
		if ( '' !== $g['url'] && $phones ) {
			?>
			<form method="post">
				<?php wp_nonce_field( 'irm_admin' ); ?>
				<input type="hidden" name="irm_action" value="gateway_test">
				<?php submit_button( __( 'Send a test wake-up to all phones', 'iran-messenger' ), 'secondary', 'submit', false ); ?>
			</form>
			<?php
		}
		$last = get_option( 'irm_gateway_last' );
		if ( is_array( $last ) ) {
			echo '<p>' . esc_html( IRM_Gateway::summary( $last ) ) . '</p>';
		}
	}

	/** Where the web app lives and whether alerts can leave this host. */
	private static function web_app_status() {
		global $wpdb;
		if ( ! is_dir( IRM_DIR . 'app' ) ) {
			echo '<p>' . esc_html__( 'This copy of the plugin does not include the web app.', 'iran-messenger' ) . '</p>';
			return;
		}
		$short = home_url( '/app' );
		echo '<p>' . esc_html__( 'Address to give to iPhone users:', 'iran-messenger' ) . ' <code>' . esc_html( $short ) . '</code></p>';
		$count = (int) $wpdb->get_var( 'SELECT COUNT(*) FROM ' . IRM_Schema::table( 'push' ) );
		echo '<p>' . esc_html( sprintf( /* translators: %d: number of browsers */ __( 'Browsers with alerts turned on: %d', 'iran-messenger' ), $count ) ) . '</p>';
		if ( '' === IRM_Push::public_key() ) {
			echo '<p><strong>' . esc_html__( 'Alerts are unavailable: this PHP has no OpenSSL elliptic-curve support.', 'iran-messenger' ) . '</strong></p>';
			return;
		}
		$last = get_option( 'irm_push_last' );
		if ( is_array( $last ) ) {
			$ok = $last['status'] >= 200 && $last['status'] < 300;
			echo '<p>' . esc_html(
				sprintf(
					/* translators: 1: time, 2: host name, 3: result */
					__( 'Last alert: %1$s to %2$s — %3$s', 'iran-messenger' ),
					wp_date( 'Y-m-d H:i:s', (int) $last['time'] ),
					$last['host'],
					$ok ? __( 'delivered to the push service', 'iran-messenger' ) : ( $last['status'] ? 'HTTP ' . $last['status'] : $last['error'] )
				)
			) . '</p>';
			if ( ! $ok && ! $last['status'] ) {
				echo '<p class="description">' . esc_html__( 'The host could not reach the push service. Ask the hosting provider to allow outgoing HTTPS to this host name.', 'iran-messenger' ) . '</p>';
			}
		} else {
			echo '<p class="description">' . esc_html__( 'No alert has been sent yet.', 'iran-messenger' ) . '</p>';
		}
	}
}
