defmodule RNS.LinkTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias RNS.Cryptography.Ed25519
  alias RNS.Cryptography.X25519
  alias RNS.Identity
  alias RNS.Link

  # ── Constants ───────────────────────────────────────────────────

  describe "constants" do
    test "ECPUBSIZE is 64 (32 encryption + 32 signing)" do
      assert Link.ecpubsize() == 64
    end

    test "KEYSIZE is 32 bytes" do
      assert Link.keysize() == 32
    end

    test "LINK_MTU_SIZE is 3 bytes" do
      assert Link.link_mtu_size() == 3
    end

    test "status constants" do
      assert Link.pending() == 0x00
      assert Link.handshake() == 0x01
      assert Link.active() == 0x02
      assert Link.stale() == 0x03
      assert Link.closed() == 0x04
    end

    test "teardown reason constants" do
      assert Link.timeout() == 0x01
      assert Link.initiator_closed() == 0x02
      assert Link.destination_closed() == 0x03
    end

    test "resource strategy constants" do
      assert Link.accept_none() == 0x00
      assert Link.accept_app() == 0x01
      assert Link.accept_all() == 0x02
    end

    test "encryption mode constants" do
      assert Link.mode_aes128_cbc() == 0x00
      assert Link.mode_aes256_cbc() == 0x01
      assert Link.mode_default() == Link.mode_aes256_cbc()
    end

    test "keepalive constants" do
      assert Link.keepalive_max() == 360
      assert Link.keepalive_min() == 5
      assert Link.stale_factor() == 2
      assert Link.keepalive_max_rtt() == 1.75
    end

    test "traffic timeout constants" do
      assert Link.traffic_timeout_factor() == 6
      assert Link.keepalive_timeout_factor() == 4
      assert Link.stale_grace() == 5
    end

    test "establishment timeout per hop" do
      assert Link.establishment_timeout_per_hop() == RNS.Packet.timeout_per_hop()
    end

    test "MTU_BYTEMASK and MODE_BYTEMASK" do
      assert Link.mtu_bytemask() == 0x1FFFFF
      assert Link.mode_bytemask() == 0xE0
    end

    test "MDU calculation matches Python" do
      # MDU = floor((MTU - IFAC_MIN_SIZE - HEADER_MINSIZE - TOKEN_OVERHEAD) / AES128_BLOCKSIZE) * AES128_BLOCKSIZE - 1
      mtu = 500
      ifac_min = 1
      # 2 + 1 + 16
      header_min = 19
      token_overhead = 48
      blocksize = 16
      expected = div(mtu - ifac_min - header_min - token_overhead, blocksize) * blocksize - 1
      assert Link.mdu() == expected
    end
  end

  # ── Struct creation ─────────────────────────────────────────────

  describe "struct" do
    test "new/0 creates a link struct with defaults" do
      link = Link.new()
      assert %Link{} = link
      assert link.status == Link.pending()
      assert link.initiator == false
      assert link.crypto.mode == Link.mode_default()
      assert link.stats.rtt == nil
      assert link.mtu == 500
      assert link.callbacks == %Link.Callbacks{}
      assert link.resource_strategy == Link.accept_none()
    end

    test "Callbacks struct has all fields nil" do
      cb = %Link.Callbacks{}
      assert cb.link_established == nil
      assert cb.link_closed == nil
      assert cb.packet == nil
      assert cb.resource == nil
      assert cb.resource_started == nil
      assert cb.resource_concluded == nil
      assert cb.remote_identified == nil
    end
  end

  # ── Signalling bytes ────────────────────────────────────────────

  describe "signalling_bytes/2" do
    test "encodes MTU and mode into 3 bytes" do
      bytes = Link.signalling_bytes(500, Link.mode_aes256_cbc())
      assert byte_size(bytes) == 3
    end

    test "different MTUs produce different signalling bytes" do
      b1 = Link.signalling_bytes(500, Link.mode_aes256_cbc())
      b2 = Link.signalling_bytes(1000, Link.mode_aes256_cbc())
      assert b1 != b2
    end

    test "mode is encoded in upper bits" do
      b0 = Link.signalling_bytes(500, Link.mode_aes128_cbc())
      b1 = Link.signalling_bytes(500, Link.mode_aes256_cbc())
      assert b0 != b1
    end

    test "MTU can be recovered from signalling bytes" do
      mtu = 500
      bytes = Link.signalling_bytes(mtu, Link.mode_aes256_cbc())
      <<b0, b1, b2>> = bytes
      recovered = (b0 <<< 16) + (b1 <<< 8) + b2 &&& Link.mtu_bytemask()
      assert recovered == mtu
    end

    test "mode can be recovered from signalling bytes" do
      mode = Link.mode_aes256_cbc()
      bytes = Link.signalling_bytes(500, mode)
      <<b0, _b1, _b2>> = bytes
      recovered = Bitwise.bsr(Bitwise.band(b0, Link.mode_bytemask()), 5)
      assert recovered == mode
    end
  end

  # ── Link ID computation ────────────────────────────────────────

  describe "link_id_from_lr_packet/1" do
    test "computes truncated hash of hashable part" do
      # Simulate a link request packet with minimal data
      # link_id should be 16 bytes (truncated hash)
      packet = %{
        data: :crypto.strong_rand_bytes(64),
        hashable_part: :crypto.strong_rand_bytes(40)
      }

      link_id = Link.link_id_from_lr_packet(packet)
      assert byte_size(link_id) == 16
    end

    test "strips extra signalling bytes from hashable part" do
      # When data > ECPUBSIZE, the extra bytes should be stripped from hashable_part
      ecpubsize = Link.ecpubsize()
      data = :crypto.strong_rand_bytes(ecpubsize + 3)
      hashable = :crypto.strong_rand_bytes(50)

      packet = %{
        data: data,
        hashable_part: hashable
      }

      link_id = Link.link_id_from_lr_packet(packet)
      assert byte_size(link_id) == 16
    end
  end

  # ── Handshake (key exchange + key derivation) ──────────────────

  describe "handshake/1" do
    test "transitions from PENDING to HANDSHAKE" do
      # Create two sides: initiator and responder
      prv = X25519.generate_keypair()
      peer_prv = X25519.generate_keypair()

      link = %Link{
        Link.new()
        | status: Link.pending(),
          crypto: %Link.CryptoState{prv: prv, mode: Link.mode_aes256_cbc()},
          peer: %Link.PeerState{peer_pub_bytes: X25519.public_key(peer_prv)},
          link_id: :crypto.strong_rand_bytes(16)
      }

      result = Link.handshake(link)
      assert {:ok, updated_link} = result
      assert updated_link.status == Link.handshake()
    end

    test "derives shared key via X25519 ECDH" do
      prv = X25519.generate_keypair()
      peer_prv = X25519.generate_keypair()

      link = %Link{
        Link.new()
        | status: Link.pending(),
          crypto: %Link.CryptoState{prv: prv, mode: Link.mode_aes256_cbc()},
          peer: %Link.PeerState{peer_pub_bytes: X25519.public_key(peer_prv)},
          link_id: :crypto.strong_rand_bytes(16)
      }

      {:ok, updated} = Link.handshake(link)
      assert updated.crypto.shared_key != nil
      assert byte_size(updated.crypto.shared_key) == 32
    end

    test "derives key using HKDF with link_id as salt" do
      prv = X25519.generate_keypair()
      peer_prv = X25519.generate_keypair()

      link = %Link{
        Link.new()
        | status: Link.pending(),
          crypto: %Link.CryptoState{prv: prv, mode: Link.mode_aes256_cbc()},
          peer: %Link.PeerState{peer_pub_bytes: X25519.public_key(peer_prv)},
          link_id: :crypto.strong_rand_bytes(16)
      }

      {:ok, updated} = Link.handshake(link)
      assert updated.crypto.derived_key != nil
      # AES-256-CBC mode: derived key is 64 bytes
      assert byte_size(updated.crypto.derived_key) == 64
    end

    test "AES-128-CBC mode derives 32-byte key" do
      prv = X25519.generate_keypair()
      peer_prv = X25519.generate_keypair()

      link = %Link{
        Link.new()
        | status: Link.pending(),
          crypto: %Link.CryptoState{prv: prv, mode: Link.mode_aes128_cbc()},
          peer: %Link.PeerState{peer_pub_bytes: X25519.public_key(peer_prv)},
          link_id: :crypto.strong_rand_bytes(16)
      }

      {:ok, updated} = Link.handshake(link)
      assert byte_size(updated.crypto.derived_key) == 32
    end

    test "both sides derive same shared key" do
      # Simulate full ECDH handshake
      initiator_prv = X25519.generate_keypair()
      responder_prv = X25519.generate_keypair()
      link_id = :crypto.strong_rand_bytes(16)

      initiator_link = %Link{
        Link.new()
        | status: Link.pending(),
          crypto: %Link.CryptoState{prv: initiator_prv, mode: Link.mode_aes256_cbc()},
          peer: %Link.PeerState{peer_pub_bytes: X25519.public_key(responder_prv)},
          link_id: link_id
      }

      responder_link = %Link{
        Link.new()
        | status: Link.pending(),
          crypto: %Link.CryptoState{prv: responder_prv, mode: Link.mode_aes256_cbc()},
          peer: %Link.PeerState{peer_pub_bytes: X25519.public_key(initiator_prv)},
          link_id: link_id
      }

      {:ok, init_done} = Link.handshake(initiator_link)
      {:ok, resp_done} = Link.handshake(responder_link)

      assert init_done.crypto.shared_key == resp_done.crypto.shared_key
      assert init_done.crypto.derived_key == resp_done.crypto.derived_key
    end

    test "returns error when not in PENDING state" do
      prv = X25519.generate_keypair()

      link = %Link{
        Link.new()
        | status: Link.active(),
          crypto: %Link.CryptoState{prv: prv},
          peer: %Link.PeerState{peer_pub_bytes: :crypto.strong_rand_bytes(32)},
          link_id: :crypto.strong_rand_bytes(16)
      }

      assert {:error, :invalid_state} = Link.handshake(link)
    end

    test "returns error when prv is nil" do
      link = %Link{
        Link.new()
        | status: Link.pending(),
          crypto: %Link.CryptoState{prv: nil},
          peer: %Link.PeerState{peer_pub_bytes: :crypto.strong_rand_bytes(32)},
          link_id: :crypto.strong_rand_bytes(16)
      }

      assert {:error, :invalid_state} = Link.handshake(link)
    end
  end

  # ── Load peer ──────────────────────────────────────────────────

  describe "load_peer/3" do
    test "sets peer public key bytes" do
      peer_prv = X25519.generate_keypair()
      peer_sig_prv = Ed25519.generate_keypair()
      pub_bytes = X25519.public_key(peer_prv)
      sig_pub_bytes = Ed25519.public_key(peer_sig_prv)

      link = Link.new()
      updated = Link.load_peer(link, pub_bytes, sig_pub_bytes)
      assert updated.peer.peer_pub_bytes == pub_bytes
      assert updated.peer.peer_sig_pub_bytes == sig_pub_bytes
    end
  end

  # ── Encrypt / Decrypt ──────────────────────────────────────────

  describe "encrypt/2 and decrypt/2" do
    setup do
      # Set up a fully handshaken link
      initiator_prv = X25519.generate_keypair()
      responder_prv = X25519.generate_keypair()
      link_id = :crypto.strong_rand_bytes(16)

      link = %Link{
        Link.new()
        | status: Link.pending(),
          crypto: %Link.CryptoState{prv: initiator_prv, mode: Link.mode_aes256_cbc()},
          peer: %Link.PeerState{peer_pub_bytes: X25519.public_key(responder_prv)},
          link_id: link_id
      }

      {:ok, handshaken} = Link.handshake(link)
      {:ok, link: handshaken}
    end

    test "encrypt returns ciphertext", %{link: link} do
      plaintext = "Hello, Reticulum!"
      {:ok, ciphertext} = Link.encrypt(link, plaintext)
      assert is_binary(ciphertext)
      assert ciphertext != plaintext
    end

    test "decrypt recovers original plaintext", %{link: link} do
      plaintext = "Hello, Reticulum!"
      {:ok, ciphertext} = Link.encrypt(link, plaintext)
      {:ok, decrypted} = Link.decrypt(link, ciphertext)
      assert decrypted == plaintext
    end

    test "encrypt/decrypt roundtrip with empty data", %{link: link} do
      plaintext = <<>>
      {:ok, ciphertext} = Link.encrypt(link, plaintext)
      {:ok, decrypted} = Link.decrypt(link, ciphertext)
      assert decrypted == plaintext
    end

    test "encrypt/decrypt roundtrip with large data", %{link: link} do
      plaintext = :crypto.strong_rand_bytes(1000)
      {:ok, ciphertext} = Link.encrypt(link, plaintext)
      {:ok, decrypted} = Link.decrypt(link, ciphertext)
      assert decrypted == plaintext
    end

    test "different encryptions produce different ciphertext (random IV)", %{link: link} do
      plaintext = "Hello, Reticulum!"
      {:ok, ct1} = Link.encrypt(link, plaintext)
      {:ok, ct2} = Link.encrypt(link, plaintext)
      assert ct1 != ct2
    end

    test "wrong key fails decryption" do
      # Create two different links with different keys
      prv1 = X25519.generate_keypair()
      peer1 = X25519.generate_keypair()
      link_id = :crypto.strong_rand_bytes(16)

      link1 = %Link{
        Link.new()
        | status: Link.pending(),
          crypto: %Link.CryptoState{prv: prv1, mode: Link.mode_aes256_cbc()},
          peer: %Link.PeerState{peer_pub_bytes: X25519.public_key(peer1)},
          link_id: link_id
      }

      prv2 = X25519.generate_keypair()
      peer2 = X25519.generate_keypair()

      link2 = %Link{
        Link.new()
        | status: Link.pending(),
          crypto: %Link.CryptoState{prv: prv2, mode: Link.mode_aes256_cbc()},
          peer: %Link.PeerState{peer_pub_bytes: X25519.public_key(peer2)},
          link_id: link_id
      }

      {:ok, l1} = Link.handshake(link1)
      {:ok, l2} = Link.handshake(link2)

      {:ok, ciphertext} = Link.encrypt(l1, "secret")
      assert {:error, _} = Link.decrypt(l2, ciphertext)
    end

    test "encrypt with AES-128-CBC mode" do
      prv = X25519.generate_keypair()
      peer_prv = X25519.generate_keypair()
      link_id = :crypto.strong_rand_bytes(16)

      link = %Link{
        Link.new()
        | status: Link.pending(),
          crypto: %Link.CryptoState{prv: prv, mode: Link.mode_aes128_cbc()},
          peer: %Link.PeerState{peer_pub_bytes: X25519.public_key(peer_prv)},
          link_id: link_id
      }

      {:ok, handshaken} = Link.handshake(link)
      {:ok, ciphertext} = Link.encrypt(handshaken, "test data")
      {:ok, decrypted} = Link.decrypt(handshaken, ciphertext)
      assert decrypted == "test data"
    end
  end

  # ── Sign / Validate ────────────────────────────────────────────

  describe "sign/2 and validate/3" do
    test "sign produces 64-byte signature" do
      sig_prv = Ed25519.generate_keypair()

      link = %Link{
        Link.new()
        | crypto: %Link.CryptoState{sig_prv: sig_prv}
      }

      signature = Link.sign(link, "test message")
      assert byte_size(signature) == 64
    end

    test "validate returns true for valid signature" do
      sig_prv = Ed25519.generate_keypair()
      sig_pub_bytes = Ed25519.public_key(sig_prv)

      link = %Link{
        Link.new()
        | crypto: %Link.CryptoState{sig_prv: sig_prv},
          peer: %Link.PeerState{peer_sig_pub_bytes: sig_pub_bytes}
      }

      message = "test message"
      signature = Link.sign(link, message)
      assert Link.validate(link, signature, message) == true
    end

    test "validate returns false for invalid signature" do
      sig_prv = Ed25519.generate_keypair()
      other_prv = Ed25519.generate_keypair()

      link = %Link{
        Link.new()
        | crypto: %Link.CryptoState{sig_prv: sig_prv},
          peer: %Link.PeerState{peer_sig_pub_bytes: Ed25519.public_key(other_prv)}
      }

      message = "test message"
      signature = Link.sign(link, message)
      assert Link.validate(link, signature, message) == false
    end
  end

  # ── Get salt / Get context ─────────────────────────────────────

  describe "salt/1 and context/1" do
    test "salt returns link_id" do
      link_id = :crypto.strong_rand_bytes(16)
      link = %Link{Link.new() | link_id: link_id}
      assert Link.salt(link) == link_id
    end

    test "context returns nil" do
      link = Link.new()
      assert Link.context(link) == nil
    end
  end

  # ── Update MDU ─────────────────────────────────────────────────

  describe "update_mdu/1" do
    test "computes MDU based on link MTU" do
      link = %Link{Link.new() | mtu: 500}
      updated = Link.update_mdu(link)
      assert is_integer(updated.mdu)
      assert updated.mdu > 0
      assert updated.mdu < 500
    end

    test "larger MTU gives larger MDU" do
      link1 = Link.update_mdu(%Link{Link.new() | mtu: 500})
      link2 = Link.update_mdu(%Link{Link.new() | mtu: 1000})
      assert link2.mdu > link1.mdu
    end
  end

  # ── Had outbound ───────────────────────────────────────────────

  describe "had_outbound/2" do
    test "updates last_outbound and last_data" do
      link = Link.new()
      updated = Link.had_outbound(link)
      assert updated.stats.last_outbound > 0
      assert updated.stats.last_data == updated.stats.last_outbound
    end

    test "keepalive flag updates last_keepalive instead of last_data" do
      link = Link.new()
      updated = Link.had_outbound(link, is_keepalive: true)
      assert updated.stats.last_outbound > 0
      assert updated.stats.last_keepalive == updated.stats.last_outbound
      assert updated.stats.last_data == 0
    end
  end

  # ── Identify ───────────────────────────────────────────────────

  describe "identify/2" do
    test "builds identify proof data with public key and signature" do
      identity = Identity.new()

      link = %Link{
        Link.new()
        | initiator: true,
          status: Link.active(),
          link_id: :crypto.strong_rand_bytes(16)
      }

      {:ok, proof_data} = Link.build_identify_data(link, identity)
      pub_key = Identity.public_key(identity)

      # proof_data = public_key (64 bytes) + signature (64 bytes)
      assert byte_size(proof_data) == 64 + 64
      # First 64 bytes should be the public key
      assert binary_part(proof_data, 0, 64) == pub_key
    end

    test "returns error when not initiator" do
      identity = Identity.new()

      link = %Link{
        Link.new()
        | initiator: false,
          status: Link.active(),
          link_id: :crypto.strong_rand_bytes(16)
      }

      assert {:error, :not_initiator_or_not_active} = Link.build_identify_data(link, identity)
    end

    test "returns error when not active" do
      identity = Identity.new()

      link = %Link{
        Link.new()
        | initiator: true,
          status: Link.pending(),
          link_id: :crypto.strong_rand_bytes(16)
      }

      assert {:error, :not_initiator_or_not_active} = Link.build_identify_data(link, identity)
    end
  end

  # ── Request ────────────────────────────────────────────────────

  describe "build_request_data/3" do
    test "builds packed request data" do
      link = %Link{
        Link.new()
        | status: Link.active(),
          stats: %Link.Stats{rtt: 0.5},
          traffic_timeout_factor: 6
      }

      {:ok, packed, _timeout} = Link.build_request_data(link, "/test/path", "request data")
      assert is_binary(packed)
    end

    test "includes path hash, timestamp, and data" do
      link = %Link{
        Link.new()
        | status: Link.active(),
          stats: %Link.Stats{rtt: 0.5},
          traffic_timeout_factor: 6
      }

      {:ok, packed, _timeout} = Link.build_request_data(link, "/test/path", "data")
      unpacked = Msgpax.unpack!(packed)
      assert is_list(unpacked)
      assert length(unpacked) == 3
      # [timestamp, path_hash, data]
      [timestamp, path_hash, data] = unpacked
      assert is_number(timestamp)
      assert is_binary(path_hash)
      # truncated hash
      assert byte_size(path_hash) == 16
      assert data == "data"
    end

    test "uses custom timeout when provided" do
      link = %Link{
        Link.new()
        | status: Link.active(),
          stats: %Link.Stats{rtt: 0.5},
          traffic_timeout_factor: 6
      }

      {:ok, _packed, timeout} = Link.build_request_data(link, "/test/path", nil, timeout: 30.0)
      assert timeout == 30.0
    end

    test "calculates timeout from RTT when not provided" do
      link = %Link{
        Link.new()
        | status: Link.active(),
          stats: %Link.Stats{rtt: 0.5},
          traffic_timeout_factor: 6
      }

      {:ok, _packed, timeout} = Link.build_request_data(link, "/test/path", nil)
      assert timeout > 0
      # Should be rtt * traffic_timeout_factor + grace time
      assert timeout >= 0.5 * 6
    end
  end

  # ── Callback setters ───────────────────────────────────────────

  describe "callback setters" do
    test "set_link_established_callback/2" do
      link = Link.new()
      cb = fn _link -> :ok end
      updated = Link.set_link_established_callback(link, cb)
      assert updated.callbacks.link_established == cb
    end

    test "set_link_closed_callback/2" do
      link = Link.new()
      cb = fn _link -> :ok end
      updated = Link.set_link_closed_callback(link, cb)
      assert updated.callbacks.link_closed == cb
    end

    test "set_packet_callback/2" do
      link = Link.new()
      cb = fn _msg, _pkt -> :ok end
      updated = Link.set_packet_callback(link, cb)
      assert updated.callbacks.packet == cb
    end

    test "set_resource_callback/2" do
      link = Link.new()
      cb = fn _resource -> true end
      updated = Link.set_resource_callback(link, cb)
      assert updated.callbacks.resource == cb
    end

    test "set_resource_started_callback/2" do
      link = Link.new()
      cb = fn _resource -> :ok end
      updated = Link.set_resource_started_callback(link, cb)
      assert updated.callbacks.resource_started == cb
    end

    test "set_resource_concluded_callback/2" do
      link = Link.new()
      cb = fn _resource -> :ok end
      updated = Link.set_resource_concluded_callback(link, cb)
      assert updated.callbacks.resource_concluded == cb
    end

    test "set_remote_identified_callback/2" do
      link = Link.new()
      cb = fn _link, _identity -> :ok end
      updated = Link.set_remote_identified_callback(link, cb)
      assert updated.callbacks.remote_identified == cb
    end
  end

  # ── Track phy stats ────────────────────────────────────────────

  describe "phy stats" do
    test "track_phy_stats enables stat tracking" do
      link = Link.new()
      updated = Link.track_phy_stats(link, true)
      assert updated.track_phy_stats == true
    end

    test "rssi returns nil when not tracking" do
      link = %Link{Link.new() | stats: %Link.Stats{rssi: -50}}
      assert Link.rssi(link) == nil
    end

    test "rssi returns value when tracking" do
      link = %Link{Link.new() | track_phy_stats: true, stats: %Link.Stats{rssi: -50}}
      assert Link.rssi(link) == -50
    end

    test "snr returns nil when not tracking" do
      link = %Link{Link.new() | stats: %Link.Stats{snr: 10.0}}
      assert Link.snr(link) == nil
    end

    test "snr returns value when tracking" do
      link = %Link{Link.new() | track_phy_stats: true, stats: %Link.Stats{snr: 10.0}}
      assert Link.snr(link) == 10.0
    end

    test "q returns nil when not tracking" do
      link = %Link{Link.new() | stats: %Link.Stats{q: 0.9}}
      assert Link.q(link) == nil
    end

    test "q returns value when tracking" do
      link = %Link{Link.new() | track_phy_stats: true, stats: %Link.Stats{q: 0.9}}
      assert Link.q(link) == 0.9
    end
  end

  # ── Establishment rate ─────────────────────────────────────────

  describe "establishment_rate/1" do
    test "returns rate in bits per second" do
      link = %Link{Link.new() | stats: %Link.Stats{establishment_rate: 100.0}}
      assert Link.establishment_rate(link) == 800.0
    end

    test "returns nil when no rate available" do
      link = Link.new()
      assert Link.establishment_rate(link) == nil
    end
  end

  # ── Remote identity ────────────────────────────────────────────

  describe "remote_identity/1" do
    test "returns nil by default" do
      link = Link.new()
      assert Link.remote_identity(link) == nil
    end

    test "returns identity when set" do
      identity = Identity.new()
      link = %Link{Link.new() | peer: %Link.PeerState{remote_identity: identity}}
      assert Link.remote_identity(link) == identity
    end
  end

  # ── Channel ────────────────────────────────────────────────────

  describe "channel/1" do
    test "creates channel on first access" do
      link = Link.new()
      {channel, updated_link} = Link.channel(link)
      assert %RNS.Channel{} = channel
      assert updated_link.channel != nil
    end

    test "returns same channel on subsequent access" do
      link = Link.new()
      {channel1, link2} = Link.channel(link)
      {channel2, _link3} = Link.channel(link2)
      # Should be the same channel struct
      assert channel1 == channel2
    end
  end

  # ── String representation ──────────────────────────────────────

  describe "String.Chars" do
    test "represents link as hex of link_id" do
      link_id =
        <<0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E,
          0x0F, 0x10>>

      link = %Link{Link.new() | link_id: link_id}
      result = to_string(link)
      assert is_binary(result)
      assert String.contains?(result, "0102")
    end

    test "handles nil link_id" do
      link = Link.new()
      result = to_string(link)
      assert is_binary(result)
    end
  end

  # ── Validate request (static, responder side) ──────────────────

  describe "validate_request/3" do
    test "creates link from valid request data" do
      # Build a request as the initiator would
      initiator_x25519 = X25519.generate_keypair()
      initiator_ed25519 = Ed25519.generate_keypair()

      request_data =
        X25519.public_key(initiator_x25519) <>
          Ed25519.public_key(initiator_ed25519)

      assert byte_size(request_data) == Link.ecpubsize()

      # Create an owner identity
      owner_identity = Identity.new()
      owner = %{identity: owner_identity}

      # Create a mock packet
      packet = %{
        data: request_data,
        hops: 1,
        destination: %{hash: :crypto.strong_rand_bytes(16)},
        receiving_interface: nil,
        raw: request_data,
        hashable_part: :crypto.strong_rand_bytes(40)
      }

      result = Link.validate_request(owner, request_data, packet)
      assert {:ok, link} = result
      assert link.peer.peer_pub_bytes == X25519.public_key(initiator_x25519)
      assert link.peer.peer_sig_pub_bytes == Ed25519.public_key(initiator_ed25519)
      assert link.status == Link.handshake()
    end

    test "rejects invalid payload size" do
      owner = %{identity: Identity.new()}
      bad_data = :crypto.strong_rand_bytes(30)

      packet = %{
        data: bad_data,
        hops: 1,
        destination: %{hash: :crypto.strong_rand_bytes(16)},
        receiving_interface: nil,
        raw: bad_data,
        hashable_part: :crypto.strong_rand_bytes(40)
      }

      assert {:error, :invalid_payload_size} = Link.validate_request(owner, bad_data, packet)
    end

    test "accepts request with signalling bytes" do
      initiator_x25519 = X25519.generate_keypair()
      initiator_ed25519 = Ed25519.generate_keypair()
      signalling = Link.signalling_bytes(500, Link.mode_aes256_cbc())

      request_data =
        X25519.public_key(initiator_x25519) <>
          Ed25519.public_key(initiator_ed25519) <>
          signalling

      assert byte_size(request_data) == Link.ecpubsize() + Link.link_mtu_size()

      owner = %{identity: Identity.new()}

      packet = %{
        data: request_data,
        hops: 1,
        destination: %{hash: :crypto.strong_rand_bytes(16)},
        receiving_interface: nil,
        raw: request_data,
        hashable_part: :crypto.strong_rand_bytes(50)
      }

      result = Link.validate_request(owner, request_data, packet)
      assert {:ok, link} = result
      assert link.status == Link.handshake()
    end
  end

  # ── Validate proof (initiator side) ────────────────────────────

  describe "validate_proof/2" do
    test "full handshake: initiator validates responder proof" do
      # === RESPONDER SETUP ===
      responder_identity = Identity.new()

      # === INITIATOR SETUP ===
      initiator_x25519 = X25519.generate_keypair()
      initiator_ed25519 = Ed25519.generate_keypair()

      # Build request data as initiator would
      signalling = Link.signalling_bytes(500, Link.mode_aes256_cbc())

      _request_data =
        X25519.public_key(initiator_x25519) <>
          Ed25519.public_key(initiator_ed25519) <>
          signalling

      # Compute the link_id from a simulated link request packet
      hashable_part = :crypto.strong_rand_bytes(40)
      link_id = Identity.truncated_hash(hashable_part)

      # === RESPONDER: receive request, handshake, generate proof ===
      responder_x25519 = X25519.generate_keypair()

      responder_link = %Link{
        Link.new()
        | status: Link.pending(),
          crypto: %Link.CryptoState{
            prv: responder_x25519,
            mode: Link.mode_aes256_cbc(),
            sig_prv: nil,
            sig_pub_bytes: nil
          },
          peer: %Link.PeerState{
            peer_pub_bytes: X25519.public_key(initiator_x25519),
            peer_sig_pub_bytes: Ed25519.public_key(initiator_ed25519)
          },
          link_id: link_id
      }

      {:ok, responder_handshaken} = Link.handshake(responder_link)

      # Responder signs: link_id + pub_bytes + sig_pub_bytes + signalling
      resp_pub_bytes = X25519.public_key(responder_x25519)

      resp_sig_pub_bytes =
        Identity.public_key(responder_identity)
        |> binary_part(32, 32)

      signed_data = link_id <> resp_pub_bytes <> resp_sig_pub_bytes <> signalling
      signature = Identity.sign(responder_identity, signed_data)

      proof_data = signature <> resp_pub_bytes <> signalling

      # === INITIATOR: validate proof ===
      # The initiator link knows the destination identity
      destination = %{identity: responder_identity, hash: :crypto.strong_rand_bytes(16)}

      initiator_link = %Link{
        Link.new()
        | status: Link.pending(),
          initiator: true,
          crypto: %Link.CryptoState{
            prv: initiator_x25519,
            pub_bytes: X25519.public_key(initiator_x25519),
            sig_pub_bytes: Ed25519.public_key(initiator_ed25519),
            mode: Link.mode_aes256_cbc()
          },
          link_id: link_id,
          destination: destination,
          request_time: System.system_time(:second) - 1
      }

      proof_packet = %{
        data: proof_data,
        raw: proof_data,
        receiving_interface: nil
      }

      result = Link.validate_proof(initiator_link, proof_packet)
      assert {:ok, activated_link} = result
      assert activated_link.status == Link.active()
      assert activated_link.stats.rtt > 0
      assert activated_link.crypto.derived_key != nil

      # Verify both sides would derive the same key
      assert activated_link.crypto.derived_key == responder_handshaken.crypto.derived_key
    end

    test "rejects proof when not in PENDING state" do
      link = %Link{Link.new() | status: Link.active(), initiator: true}
      packet = %{data: :crypto.strong_rand_bytes(100), raw: <<>>, receiving_interface: nil}

      assert {:error, _} = Link.validate_proof(link, packet)
    end

    test "rejects proof with invalid signature" do
      responder_identity = Identity.new()
      fake_identity = Identity.new()

      initiator_x25519 = X25519.generate_keypair()
      initiator_ed25519 = Ed25519.generate_keypair()

      signalling = Link.signalling_bytes(500, Link.mode_aes256_cbc())
      link_id = :crypto.strong_rand_bytes(16)

      responder_x25519 = X25519.generate_keypair()
      resp_pub_bytes = X25519.public_key(responder_x25519)

      resp_sig_pub_bytes =
        Identity.public_key(responder_identity)
        |> binary_part(32, 32)

      signed_data = link_id <> resp_pub_bytes <> resp_sig_pub_bytes <> signalling
      # Sign with WRONG identity
      bad_signature = Identity.sign(fake_identity, signed_data)
      proof_data = bad_signature <> resp_pub_bytes <> signalling

      destination = %{identity: responder_identity, hash: :crypto.strong_rand_bytes(16)}

      initiator_link = %Link{
        Link.new()
        | status: Link.pending(),
          initiator: true,
          crypto: %Link.CryptoState{
            prv: initiator_x25519,
            pub_bytes: X25519.public_key(initiator_x25519),
            sig_pub_bytes: Ed25519.public_key(initiator_ed25519),
            mode: Link.mode_aes256_cbc()
          },
          link_id: link_id,
          destination: destination,
          request_time: System.system_time(:second)
      }

      proof_packet = %{
        data: proof_data,
        raw: proof_data,
        receiving_interface: nil
      }

      assert {:error, :invalid_signature} = Link.validate_proof(initiator_link, proof_packet)
    end
  end

  # ── RTT packet handling ────────────────────────────────────────

  describe "rtt_packet/2" do
    test "processes RTT packet and activates responder link" do
      # Setup both sides
      initiator_x25519 = X25519.generate_keypair()
      responder_x25519 = X25519.generate_keypair()
      link_id = :crypto.strong_rand_bytes(16)

      # Responder side: handshake complete, waiting for RTT
      resp_link = %Link{
        Link.new()
        | status: Link.pending(),
          crypto: %Link.CryptoState{prv: responder_x25519, mode: Link.mode_aes256_cbc()},
          peer: %Link.PeerState{peer_pub_bytes: X25519.public_key(initiator_x25519)},
          link_id: link_id,
          request_time: System.system_time(:second) - 1
      }

      {:ok, resp_handshaken} = Link.handshake(resp_link)

      # Initiator side: encrypt RTT data
      init_link = %Link{
        Link.new()
        | status: Link.pending(),
          crypto: %Link.CryptoState{prv: initiator_x25519, mode: Link.mode_aes256_cbc()},
          peer: %Link.PeerState{peer_pub_bytes: X25519.public_key(responder_x25519)},
          link_id: link_id
      }

      {:ok, init_handshaken} = Link.handshake(init_link)

      # Initiator encrypts RTT value
      rtt_value = 0.25
      rtt_data = Msgpax.pack!(rtt_value) |> IO.iodata_to_binary()
      {:ok, encrypted_rtt} = Link.encrypt(init_handshaken, rtt_data)

      # Responder decrypts and processes RTT packet
      rtt_packet = %{data: encrypted_rtt}
      result = Link.rtt_packet(resp_handshaken, rtt_packet)
      assert {:ok, activated} = result
      assert activated.status == Link.active()
      assert activated.stats.rtt != nil
      assert activated.stats.rtt >= rtt_value
    end
  end

  # ── Mode descriptions ──────────────────────────────────────────

  describe "mode_description/1" do
    test "returns description for known modes" do
      assert Link.mode_description(Link.mode_aes128_cbc()) == "AES_128_CBC"
      assert Link.mode_description(Link.mode_aes256_cbc()) == "AES_256_CBC"
    end
  end
end
