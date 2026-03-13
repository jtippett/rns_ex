defmodule RNS.DestinationTest do
  use ExUnit.Case, async: true

  alias RNS.Destination
  alias RNS.Identity

  # ── Constants ───────────────────────────────────────────────────

  describe "constants" do
    test "SINGLE is 0x00" do
      assert Destination.single() == 0x00
    end

    test "GROUP is 0x01" do
      assert Destination.group() == 0x01
    end

    test "PLAIN is 0x02" do
      assert Destination.plain() == 0x02
    end

    test "LINK is 0x03" do
      assert Destination.link() == 0x03
    end

    test "types list" do
      assert Destination.types() == [0x00, 0x01, 0x02, 0x03]
    end

    test "PROVE_NONE is 0x21" do
      assert Destination.prove_none() == 0x21
    end

    test "PROVE_APP is 0x22" do
      assert Destination.prove_app() == 0x22
    end

    test "PROVE_ALL is 0x23" do
      assert Destination.prove_all() == 0x23
    end

    test "proof_strategies list" do
      assert Destination.proof_strategies() == [0x21, 0x22, 0x23]
    end

    test "ALLOW_NONE is 0x00" do
      assert Destination.allow_none() == 0x00
    end

    test "ALLOW_ALL is 0x01" do
      assert Destination.allow_all() == 0x01
    end

    test "ALLOW_LIST is 0x02" do
      assert Destination.allow_list() == 0x02
    end

    test "request_policies list" do
      assert Destination.request_policies() == [0x00, 0x01, 0x02]
    end

    test "IN is 0x11" do
      assert Destination.direction_in() == 0x11
    end

    test "OUT is 0x12" do
      assert Destination.direction_out() == 0x12
    end

    test "directions list" do
      assert Destination.directions() == [0x11, 0x12]
    end

    test "PR_TAG_WINDOW is 30" do
      assert Destination.pr_tag_window() == 30
    end

    test "RATCHET_COUNT is 512" do
      assert Destination.ratchet_count() == 512
    end

    test "RATCHET_INTERVAL is 1800" do
      assert Destination.default_ratchet_interval() == 1800
    end
  end

  # ── Static hash computation ─────────────────────────────────────

  describe "expand_name/3" do
    test "app_name only" do
      assert Destination.expand_name(nil, "myapp", []) == "myapp"
    end

    test "app_name with aspects" do
      assert Destination.expand_name(nil, "myapp", ["service", "v1"]) == "myapp.service.v1"
    end

    test "app_name with identity" do
      id = Identity.new()
      result = Destination.expand_name(id, "myapp", ["aspect"])
      assert result == "myapp.aspect.#{id.hexhash}"
    end

    test "app_name with aspects and identity" do
      id = Identity.new()
      result = Destination.expand_name(id, "myapp", ["svc", "data"])
      assert result == "myapp.svc.data.#{id.hexhash}"
    end
  end

  describe "compute_name_hash/2" do
    test "returns 10 bytes (NAME_HASH_LENGTH // 8)" do
      name_hash = Destination.compute_name_hash("myapp", ["service"])
      assert byte_size(name_hash) == 10
    end

    test "same inputs produce same hash" do
      h1 = Destination.compute_name_hash("myapp", ["svc"])
      h2 = Destination.compute_name_hash("myapp", ["svc"])
      assert h1 == h2
    end

    test "different inputs produce different hashes" do
      h1 = Destination.compute_name_hash("myapp", ["svc1"])
      h2 = Destination.compute_name_hash("myapp", ["svc2"])
      refute h1 == h2
    end

    test "computed as SHA-256 of name string truncated to 10 bytes" do
      name_str = "myapp.service"
      expected = binary_part(RNS.Cryptography.Hashes.sha256(name_str), 0, 10)
      assert Destination.compute_name_hash("myapp", ["service"]) == expected
    end
  end

  describe "compute_hash/3" do
    test "returns 16 bytes (TRUNCATED_HASHLENGTH // 8)" do
      id = Identity.new()
      hash = Destination.compute_hash(id, "myapp", ["svc"])
      assert byte_size(hash) == 16
    end

    test "PLAIN destination hash (no identity)" do
      hash = Destination.compute_hash(nil, "myapp", ["svc"])
      assert byte_size(hash) == 16

      # Should be SHA-256(name_hash) truncated to 16 bytes
      name_hash = Destination.compute_name_hash("myapp", ["svc"])
      expected = binary_part(RNS.Cryptography.Hashes.sha256(name_hash), 0, 16)
      assert hash == expected
    end

    test "SINGLE destination hash with identity" do
      id = Identity.new()
      hash = Destination.compute_hash(id, "myapp", ["svc"])

      # Should be SHA-256(name_hash + identity.hash) truncated to 16 bytes
      name_hash = Destination.compute_name_hash("myapp", ["svc"])
      expected = binary_part(RNS.Cryptography.Hashes.sha256(name_hash <> id.hash), 0, 16)
      assert hash == expected
    end

    test "accepts raw binary identity hash (16 bytes)" do
      raw_hash = :crypto.strong_rand_bytes(16)
      hash = Destination.compute_hash(raw_hash, "myapp", ["svc"])
      assert byte_size(hash) == 16

      name_hash = Destination.compute_name_hash("myapp", ["svc"])
      expected = binary_part(RNS.Cryptography.Hashes.sha256(name_hash <> raw_hash), 0, 16)
      assert hash == expected
    end

    test "same inputs produce same hash" do
      id = Identity.new()
      h1 = Destination.compute_hash(id, "myapp", ["svc"])
      h2 = Destination.compute_hash(id, "myapp", ["svc"])
      assert h1 == h2
    end
  end

  describe "hash/3" do
    test "is an alias for compute_hash" do
      id = Identity.new()

      assert Destination.hash(id, "myapp", ["svc"]) ==
               Destination.compute_hash(id, "myapp", ["svc"])
    end
  end

  describe "app_and_aspects_from_name/1" do
    test "splits name correctly" do
      assert Destination.app_and_aspects_from_name("myapp.svc.v1") == {"myapp", ["svc", "v1"]}
    end

    test "app only" do
      assert Destination.app_and_aspects_from_name("myapp") == {"myapp", []}
    end
  end

  describe "hash_from_name_and_identity/2" do
    test "produces same hash as hash/3" do
      id = Identity.new()
      h1 = Destination.hash_from_name_and_identity("myapp.svc", id)
      h2 = Destination.hash(id, "myapp", ["svc"])
      assert h1 == h2
    end
  end

  # ── Construction ────────────────────────────────────────────────

  describe "new/5 — SINGLE IN" do
    test "creates destination with auto-generated identity" do
      dest =
        Destination.new(nil, Destination.direction_in(), Destination.single(), "myapp", ["svc"])

      assert dest.type == Destination.single()
      assert dest.direction == Destination.direction_in()
      assert dest.identity != nil
      assert dest.identity.prv_bytes != nil
      assert byte_size(dest.hash) == 16
      assert is_binary(dest.hexhash)
      assert byte_size(dest.name_hash) == 10
    end

    test "name includes identity hexhash" do
      dest =
        Destination.new(nil, Destination.direction_in(), Destination.single(), "myapp", ["svc"])

      assert String.contains?(dest.name, dest.identity.hexhash)
    end

    test "creates destination with provided identity" do
      id = Identity.new()

      dest =
        Destination.new(id, Destination.direction_in(), Destination.single(), "myapp", ["svc"])

      assert dest.identity == id
    end

    test "default values" do
      dest = Destination.new(nil, Destination.direction_in(), Destination.single(), "myapp")
      assert dest.accept_link_requests == true
      assert dest.proof_strategy == Destination.prove_none()
      assert dest.mtu == 0
      assert dest.ratchets == nil
      assert dest.enforce_ratchets == false
      assert dest.links == []
      assert dest.request_handlers == %{}
      assert dest.path_responses == %{}
    end
  end

  describe "new/5 — SINGLE OUT" do
    test "creates destination with provided identity" do
      id = Identity.new()

      dest =
        Destination.new(id, Destination.direction_out(), Destination.single(), "myapp", ["svc"])

      assert dest.type == Destination.single()
      assert dest.direction == Destination.direction_out()
      assert dest.identity == id
    end

    test "raises without identity" do
      assert_raise ArgumentError, ~r/outbound.*identity/i, fn ->
        Destination.new(nil, Destination.direction_out(), Destination.single(), "myapp")
      end
    end
  end

  describe "new/5 — PLAIN" do
    test "creates PLAIN IN without identity" do
      dest =
        Destination.new(nil, Destination.direction_in(), Destination.plain(), "myapp", ["svc"])

      assert dest.type == Destination.plain()
      assert dest.identity == nil
    end

    test "creates PLAIN OUT without identity" do
      dest = Destination.new(nil, Destination.direction_out(), Destination.plain(), "myapp")
      assert dest.type == Destination.plain()
      assert dest.identity == nil
    end

    test "raises with identity" do
      id = Identity.new()

      assert_raise ArgumentError, ~r/PLAIN.*identity/i, fn ->
        Destination.new(id, Destination.direction_in(), Destination.plain(), "myapp")
      end
    end
  end

  describe "new/5 — GROUP" do
    test "creates GROUP IN with auto identity" do
      dest = Destination.new(nil, Destination.direction_in(), Destination.group(), "myapp")
      assert dest.type == Destination.group()
      assert dest.identity != nil
    end

    test "creates GROUP IN with provided identity" do
      id = Identity.new()
      dest = Destination.new(id, Destination.direction_in(), Destination.group(), "myapp")
      assert dest.identity == id
    end
  end

  describe "new/5 — validation" do
    test "raises on dots in app_name" do
      assert_raise ArgumentError, ~r/Dots/i, fn ->
        Destination.new(nil, Destination.direction_in(), Destination.plain(), "my.app")
      end
    end

    test "raises on dots in aspects" do
      assert_raise ArgumentError, ~r/Dots/i, fn ->
        Destination.new(nil, Destination.direction_in(), Destination.plain(), "myapp", [
          "bad.aspect"
        ])
      end
    end

    test "raises on invalid type" do
      assert_raise ArgumentError, ~r/destination type/i, fn ->
        Destination.new(nil, Destination.direction_in(), 0xFF, "myapp")
      end
    end

    test "raises on invalid direction" do
      assert_raise ArgumentError, ~r/destination direction/i, fn ->
        Destination.new(nil, 0xFF, Destination.plain(), "myapp")
      end
    end
  end

  describe "new/5 — hash derivation" do
    test "hash matches static compute_hash for SINGLE with provided identity" do
      id = Identity.new()
      # When identity is provided, hexhash is NOT appended to aspects
      dest =
        Destination.new(id, Destination.direction_in(), Destination.single(), "myapp", ["svc"])

      expected = Destination.compute_hash(id, "myapp", ["svc"])
      assert dest.hash == expected
    end

    test "hash matches static compute_hash for PLAIN" do
      dest =
        Destination.new(nil, Destination.direction_in(), Destination.plain(), "myapp", ["svc"])

      expected = Destination.compute_hash(nil, "myapp", ["svc"])
      assert dest.hash == expected
    end

    test "hexhash is lowercase hex of hash" do
      dest = Destination.new(nil, Destination.direction_in(), Destination.plain(), "myapp")
      assert dest.hexhash == Base.encode16(dest.hash, case: :lower)
    end

    test "auto-generated identity appends hexhash to aspects for hash" do
      # When identity is nil for SINGLE IN, a new identity is created
      # and its hexhash is appended to aspects
      dest =
        Destination.new(nil, Destination.direction_in(), Destination.single(), "myapp", ["svc"])

      expected = Destination.compute_hash(dest.identity, "myapp", ["svc", dest.identity.hexhash])
      assert dest.hash == expected
    end
  end

  # ── Encryption / Decryption ─────────────────────────────────────

  describe "encrypt/decrypt — PLAIN" do
    test "encrypt is passthrough" do
      dest = Destination.new(nil, Destination.direction_in(), Destination.plain(), "myapp")
      assert Destination.encrypt(dest, "hello") == "hello"
    end

    test "decrypt is passthrough" do
      dest = Destination.new(nil, Destination.direction_in(), Destination.plain(), "myapp")
      assert Destination.decrypt(dest, "hello") == "hello"
    end
  end

  describe "encrypt/decrypt — GROUP" do
    test "roundtrip after create_keys" do
      id = Identity.new()
      dest = Destination.new(id, Destination.direction_in(), Destination.group(), "myapp")
      dest = Destination.create_keys(dest)
      plaintext = "group secret"
      ciphertext = Destination.encrypt(dest, plaintext)
      assert Destination.decrypt(dest, ciphertext) == plaintext
    end

    test "raises without key on encrypt" do
      id = Identity.new()
      dest = Destination.new(id, Destination.direction_in(), Destination.group(), "myapp")

      assert_raise ArgumentError, ~r/No private key/i, fn ->
        Destination.encrypt(dest, "data")
      end
    end

    test "raises without key on decrypt" do
      id = Identity.new()
      dest = Destination.new(id, Destination.direction_in(), Destination.group(), "myapp")

      assert_raise ArgumentError, ~r/No private key/i, fn ->
        Destination.decrypt(dest, "data")
      end
    end

    test "load_private_key enables encrypt/decrypt" do
      id = Identity.new()
      dest = Destination.new(id, Destination.direction_in(), Destination.group(), "myapp")
      dest = Destination.create_keys(dest)
      key = Destination.private_key(dest)

      # Create new destination and load the key
      dest2 = Destination.new(id, Destination.direction_in(), Destination.group(), "myapp2")
      dest2 = Destination.load_private_key(dest2, key)

      plaintext = "shared group data"
      ciphertext = Destination.encrypt(dest, plaintext)
      assert Destination.decrypt(dest2, ciphertext) == plaintext
    end
  end

  # ── Signing ─────────────────────────────────────────────────────

  describe "sign/2" do
    test "SINGLE destination can sign" do
      id = Identity.new()
      dest = Destination.new(id, Destination.direction_in(), Destination.single(), "myapp")
      sig = Destination.sign(dest, "message")
      assert byte_size(sig) == 64
    end

    test "signature is valid" do
      id = Identity.new()
      dest = Destination.new(id, Destination.direction_in(), Destination.single(), "myapp")
      message = "verify me"
      sig = Destination.sign(dest, message)
      assert Identity.validate(id, sig, message) == true
    end

    test "non-SINGLE returns nil" do
      dest = Destination.new(nil, Destination.direction_in(), Destination.plain(), "myapp")
      assert Destination.sign(dest, "msg") == nil
    end

    test "GROUP returns nil" do
      id = Identity.new()
      dest = Destination.new(id, Destination.direction_in(), Destination.group(), "myapp")
      assert Destination.sign(dest, "msg") == nil
    end
  end

  # ── GROUP key management ────────────────────────────────────────

  describe "GROUP key management" do
    test "create_keys generates 64-byte key" do
      id = Identity.new()
      dest = Destination.new(id, Destination.direction_in(), Destination.group(), "myapp")
      dest = Destination.create_keys(dest)
      assert byte_size(Destination.private_key(dest)) == 64
    end

    test "create_keys raises for PLAIN" do
      dest = Destination.new(nil, Destination.direction_in(), Destination.plain(), "myapp")

      assert_raise ArgumentError, ~r/plain/i, fn ->
        Destination.create_keys(dest)
      end
    end

    test "create_keys raises for SINGLE" do
      id = Identity.new()
      dest = Destination.new(id, Destination.direction_in(), Destination.single(), "myapp")

      assert_raise ArgumentError, ~r/single/i, fn ->
        Destination.create_keys(dest)
      end
    end

    test "private_key raises for PLAIN" do
      dest = Destination.new(nil, Destination.direction_in(), Destination.plain(), "myapp")

      assert_raise ArgumentError, ~r/plain/i, fn ->
        Destination.private_key(dest)
      end
    end

    test "private_key raises for SINGLE" do
      id = Identity.new()
      dest = Destination.new(id, Destination.direction_in(), Destination.single(), "myapp")

      assert_raise ArgumentError, ~r/single/i, fn ->
        Destination.private_key(dest)
      end
    end

    test "load_private_key raises for PLAIN" do
      dest = Destination.new(nil, Destination.direction_in(), Destination.plain(), "myapp")

      assert_raise ArgumentError, ~r/plain/i, fn ->
        Destination.load_private_key(dest, :crypto.strong_rand_bytes(64))
      end
    end

    test "load_private_key raises for SINGLE" do
      id = Identity.new()
      dest = Destination.new(id, Destination.direction_in(), Destination.single(), "myapp")

      assert_raise ArgumentError, ~r/single/i, fn ->
        Destination.load_private_key(dest, :crypto.strong_rand_bytes(64))
      end
    end
  end

  # ── Callback registration ───────────────────────────────────────

  describe "callback registration" do
    test "set_link_established_callback" do
      dest = Destination.new(nil, Destination.direction_in(), Destination.plain(), "myapp")
      cb = fn _link -> :ok end
      dest = Destination.set_link_established_callback(dest, cb)
      assert dest.callbacks.link_established == cb
    end

    test "set_packet_callback" do
      dest = Destination.new(nil, Destination.direction_in(), Destination.plain(), "myapp")
      cb = fn _data, _packet -> :ok end
      dest = Destination.set_packet_callback(dest, cb)
      assert dest.callbacks.packet == cb
    end

    test "set_proof_requested_callback" do
      dest = Destination.new(nil, Destination.direction_in(), Destination.plain(), "myapp")
      cb = fn _packet -> true end
      dest = Destination.set_proof_requested_callback(dest, cb)
      assert dest.callbacks.proof_requested == cb
    end
  end

  # ── Proof strategy ──────────────────────────────────────────────

  describe "set_proof_strategy/2" do
    test "accepts valid strategies" do
      dest = Destination.new(nil, Destination.direction_in(), Destination.plain(), "myapp")

      dest = Destination.set_proof_strategy(dest, Destination.prove_none())
      assert dest.proof_strategy == Destination.prove_none()

      dest = Destination.set_proof_strategy(dest, Destination.prove_app())
      assert dest.proof_strategy == Destination.prove_app()

      dest = Destination.set_proof_strategy(dest, Destination.prove_all())
      assert dest.proof_strategy == Destination.prove_all()
    end

    test "raises for invalid strategy" do
      dest = Destination.new(nil, Destination.direction_in(), Destination.plain(), "myapp")

      assert_raise ArgumentError, ~r/Unsupported proof strategy/i, fn ->
        Destination.set_proof_strategy(dest, 0xFF)
      end
    end
  end

  # ── Default app data ────────────────────────────────────────────

  describe "default_app_data" do
    test "set_default_app_data with bytes" do
      dest = Destination.new(nil, Destination.direction_in(), Destination.plain(), "myapp")
      dest = Destination.set_default_app_data(dest, "app data bytes")
      assert dest.default_app_data == "app data bytes"
    end

    test "set_default_app_data with callable" do
      dest = Destination.new(nil, Destination.direction_in(), Destination.plain(), "myapp")
      cb = fn -> "dynamic data" end
      dest = Destination.set_default_app_data(dest, cb)
      assert dest.default_app_data == cb
    end

    test "clear_default_app_data" do
      dest = Destination.new(nil, Destination.direction_in(), Destination.plain(), "myapp")
      dest = Destination.set_default_app_data(dest, "data")
      dest = Destination.clear_default_app_data(dest)
      assert dest.default_app_data == nil
    end
  end

  # ── Link acceptance ─────────────────────────────────────────────

  describe "accepts_links" do
    test "defaults to true" do
      dest = Destination.new(nil, Destination.direction_in(), Destination.plain(), "myapp")
      assert Destination.accepts_links?(dest) == true
    end

    test "set to false" do
      dest = Destination.new(nil, Destination.direction_in(), Destination.plain(), "myapp")
      dest = Destination.set_accepts_links(dest, false)
      assert Destination.accepts_links?(dest) == false
    end

    test "set back to true" do
      dest = Destination.new(nil, Destination.direction_in(), Destination.plain(), "myapp")
      dest = Destination.set_accepts_links(dest, false)
      dest = Destination.set_accepts_links(dest, true)
      assert Destination.accepts_links?(dest) == true
    end
  end

  # ── Request handlers ────────────────────────────────────────────

  describe "register_request_handler/3" do
    test "registers a handler" do
      dest = Destination.new(nil, Destination.direction_in(), Destination.plain(), "myapp")
      gen = fn _path, _data, _req_id, _link_id, _remote_id, _at -> "response" end

      dest = Destination.register_request_handler(dest, "/test", response_generator: gen)
      path_hash = Identity.truncated_hash("/test")
      assert Map.has_key?(dest.request_handlers, path_hash)

      handler = dest.request_handlers[path_hash]
      assert handler.path == "/test"
      assert handler.allow == Destination.allow_none()
      assert handler.auto_compress == true
    end

    test "registers with ALLOW_ALL policy" do
      dest = Destination.new(nil, Destination.direction_in(), Destination.plain(), "myapp")
      gen = fn _p, _d, _r, _l, _ri, _a -> "ok" end

      dest =
        Destination.register_request_handler(dest, "/api",
          response_generator: gen,
          allow: Destination.allow_all()
        )

      path_hash = Identity.truncated_hash("/api")
      assert dest.request_handlers[path_hash].allow == Destination.allow_all()
    end

    test "raises on empty path" do
      dest = Destination.new(nil, Destination.direction_in(), Destination.plain(), "myapp")

      assert_raise ArgumentError, ~r/Invalid path/i, fn ->
        Destination.register_request_handler(dest, "", response_generator: fn -> :ok end)
      end
    end

    test "raises on nil path" do
      dest = Destination.new(nil, Destination.direction_in(), Destination.plain(), "myapp")

      assert_raise ArgumentError, ~r/Invalid path/i, fn ->
        Destination.register_request_handler(dest, nil, response_generator: fn -> :ok end)
      end
    end

    test "raises without response_generator" do
      dest = Destination.new(nil, Destination.direction_in(), Destination.plain(), "myapp")

      assert_raise ArgumentError, ~r/Invalid response generator/i, fn ->
        Destination.register_request_handler(dest, "/test")
      end
    end

    test "raises on invalid policy" do
      dest = Destination.new(nil, Destination.direction_in(), Destination.plain(), "myapp")
      gen = fn -> :ok end

      assert_raise ArgumentError, ~r/Invalid request policy/i, fn ->
        Destination.register_request_handler(dest, "/test",
          response_generator: gen,
          allow: 0xFF
        )
      end
    end
  end

  describe "deregister_request_handler/2" do
    test "removes existing handler" do
      dest = Destination.new(nil, Destination.direction_in(), Destination.plain(), "myapp")
      gen = fn -> :ok end
      dest = Destination.register_request_handler(dest, "/test", response_generator: gen)

      {true, dest} = Destination.deregister_request_handler(dest, "/test")
      path_hash = Identity.truncated_hash("/test")
      refute Map.has_key?(dest.request_handlers, path_hash)
    end

    test "returns false for non-existent handler" do
      dest = Destination.new(nil, Destination.direction_in(), Destination.plain(), "myapp")
      {false, _dest} = Destination.deregister_request_handler(dest, "/nonexistent")
    end
  end

  # ── Receive ─────────────────────────────────────────────────────

  describe "receive_packet/2" do
    test "PLAIN destination passes through data" do
      dest = Destination.new(nil, Destination.direction_in(), Destination.plain(), "myapp")
      test_pid = self()

      dest =
        Destination.set_packet_callback(dest, fn data, _pkt ->
          send(test_pid, {:received, data})
        end)

      packet = %RNS.Packet{
        packet_type: RNS.Packet.data(),
        data: "hello plain"
      }

      {true, _dest} = Destination.receive_packet(dest, packet)
      assert_receive {:received, "hello plain"}
    end

    test "link request returns true when accepting links" do
      dest = Destination.new(nil, Destination.direction_in(), Destination.plain(), "myapp")

      packet = %RNS.Packet{
        packet_type: RNS.Packet.linkrequest(),
        data: "link request data"
      }

      {true, _dest} = Destination.receive_packet(dest, packet)
    end

    test "link request returns false when not accepting links" do
      dest = Destination.new(nil, Destination.direction_in(), Destination.plain(), "myapp")
      dest = Destination.set_accepts_links(dest, false)

      packet = %RNS.Packet{
        packet_type: RNS.Packet.linkrequest(),
        data: "link request data"
      }

      {false, _dest} = Destination.receive_packet(dest, packet)
    end
  end

  # ── String representation ───────────────────────────────────────

  describe "String.Chars" do
    test "to_string format" do
      dest =
        Destination.new(nil, Destination.direction_in(), Destination.plain(), "myapp", ["svc"])

      str = to_string(dest)
      assert str == "<#{dest.name}:#{dest.hexhash}>"
    end

    test "interpolation works" do
      dest = Destination.new(nil, Destination.direction_in(), Destination.plain(), "myapp")
      assert "#{dest}" == "<#{dest.name}:#{dest.hexhash}>"
    end
  end

  # ── Announce (basic, no store needed) ───────────────────────────

  describe "announce/2 — basic" do
    test "raises for non-SINGLE" do
      id = Identity.new()
      dest = Destination.new(id, Destination.direction_in(), Destination.group(), "myapp")

      assert_raise ArgumentError, ~r/SINGLE/i, fn ->
        Destination.announce(dest)
      end
    end
  end
end

# Tests that require IdentityStore (ratchets, store operations, SINGLE encrypt)
defmodule RNS.DestinationStoreTest do
  use ExUnit.Case, async: false

  alias RNS.Destination
  alias RNS.Identity

  setup do
    # Clear ETS tables for clean state (IdentityStore is supervised by the application)
    RNS.Test.SupervisedHelpers.clear_identity_store_tables()
    %{store: GenServer.whereis(RNS.IdentityStore)}
  end

  # ── SINGLE encrypt/decrypt (needs IdentityStore for ratchet lookup) ──

  describe "encrypt/decrypt — SINGLE" do
    test "roundtrip encrypt/decrypt" do
      id = Identity.new()
      dest = Destination.new(id, Destination.direction_in(), Destination.single(), "myapp")
      plaintext = "secret message"
      ciphertext = Destination.encrypt(dest, plaintext)
      assert ciphertext != plaintext
      assert Destination.decrypt(dest, ciphertext) == plaintext
    end

    test "different plaintexts produce different ciphertexts" do
      id = Identity.new()
      dest = Destination.new(id, Destination.direction_in(), Destination.single(), "myapp")
      c1 = Destination.encrypt(dest, "msg1")
      c2 = Destination.encrypt(dest, "msg2")
      refute c1 == c2
    end

    test "empty plaintext roundtrip" do
      id = Identity.new()
      dest = Destination.new(id, Destination.direction_in(), Destination.single(), "myapp")
      ciphertext = Destination.encrypt(dest, <<>>)
      assert Destination.decrypt(dest, ciphertext) == <<>>
    end

    test "returns false on decryption failure" do
      id = Identity.new()
      dest = Destination.new(id, Destination.direction_in(), Destination.single(), "myapp")

      packet = %RNS.Packet{
        packet_type: RNS.Packet.data(),
        data: "not valid ciphertext that is long enough to be processed"
      }

      {false, _dest} = Destination.receive_packet(dest, packet)
    end
  end

  # ── Announce (needs IdentityStore) ──────────────────────────────

  describe "announce/2" do
    test "creates announce packet without sending" do
      id = Identity.new()
      dest = Destination.new(id, Destination.direction_in(), Destination.single(), "myapp")

      {packet, dest2} = Destination.announce(dest, send: false)
      assert %RNS.Packet{} = packet
      assert packet.packet_type == RNS.Packet.announce()
      assert packet.context == RNS.Packet.context_none()
      assert dest2.type == Destination.single()
    end

    test "announce data contains public key, name hash, random hash, and signature" do
      id = Identity.new()
      dest = Destination.new(id, Destination.direction_in(), Destination.single(), "myapp")

      {packet, _dest} = Destination.announce(dest, send: false)
      data = packet.data

      # Without ratchets: public_key (64) + name_hash (10) + random_hash (10) + signature (64) = 148
      assert byte_size(data) >= 148

      # Extract public key (first 64 bytes)
      <<pub_key::binary-size(64), _rest::binary>> = data
      assert pub_key == Identity.public_key(id)
    end

    test "announce with app_data" do
      id = Identity.new()
      dest = Destination.new(id, Destination.direction_in(), Destination.single(), "myapp")

      {packet, _dest} = Destination.announce(dest, send: false, app_data: "my app data")
      # 148 base + 11 bytes app_data
      assert byte_size(packet.data) == 148 + 11
    end

    test "announce with default_app_data (bytes)" do
      id = Identity.new()
      dest = Destination.new(id, Destination.direction_in(), Destination.single(), "myapp")
      dest = Destination.set_default_app_data(dest, "default data")

      {packet, _dest} = Destination.announce(dest, send: false)
      assert byte_size(packet.data) == 148 + 12
    end

    test "announce with default_app_data (callable)" do
      id = Identity.new()
      dest = Destination.new(id, Destination.direction_in(), Destination.single(), "myapp")
      dest = Destination.set_default_app_data(dest, fn -> "callable data" end)

      {packet, _dest} = Destination.announce(dest, send: false)
      assert byte_size(packet.data) == 148 + 13
    end

    test "explicit app_data overrides default" do
      id = Identity.new()
      dest = Destination.new(id, Destination.direction_in(), Destination.single(), "myapp")
      dest = Destination.set_default_app_data(dest, "default")

      {packet, _dest} = Destination.announce(dest, send: false, app_data: "explicit")
      # 148 base + 8 bytes
      assert byte_size(packet.data) == 148 + 8
    end

    test "announce signature is valid" do
      id = Identity.new()
      dest = Destination.new(id, Destination.direction_in(), Destination.single(), "myapp")

      {packet, _dest} = Destination.announce(dest, send: false)
      data = packet.data

      # Parse announce data: pub_key (64) + name_hash (10) + random_hash (10) + signature (64)
      <<pub_key::binary-size(64), name_hash::binary-size(10), random_hash::binary-size(10),
        signature::binary-size(64)>> = data

      # Reconstruct signed_data (includes destination hash)
      signed_data = dest.hash <> pub_key <> name_hash <> random_hash
      assert Identity.validate(id, signature, signed_data)
    end

    test "announce with path_response context" do
      id = Identity.new()
      dest = Destination.new(id, Destination.direction_in(), Destination.single(), "myapp")

      {packet, _dest} = Destination.announce(dest, send: false, path_response: true)
      assert packet.context == RNS.Packet.context_path_response()
    end

    test "path response caching with tag" do
      id = Identity.new()
      dest = Destination.new(id, Destination.direction_in(), Destination.single(), "myapp")

      tag = :crypto.strong_rand_bytes(16)
      {_packet1, dest} = Destination.announce(dest, send: false, tag: tag)
      assert Map.has_key?(dest.path_responses, tag)

      # Second announce with same tag as path_response should use cache
      {packet2, _dest} = Destination.announce(dest, send: false, path_response: true, tag: tag)
      assert packet2 != nil
    end
  end

  # ── Ratchet management ─────────────────────────────────────────

  describe "ratchet management" do
    test "enable_ratchets initializes empty ratchet list" do
      id = Identity.new()
      dest = Destination.new(id, Destination.direction_in(), Destination.single(), "myapp")

      path = Path.join(System.tmp_dir!(), "test_ratchets_#{:erlang.unique_integer([:positive])}")

      on_exit(fn ->
        File.rm(path)
        File.rm(path <> ".tmp")
      end)

      dest = Destination.enable_ratchets(dest, path)
      assert dest.ratchets == []
      assert dest.latest_ratchet_time == 0
      assert dest.ratchets_path == path
    end

    test "rotate_ratchets adds a new ratchet" do
      id = Identity.new()
      dest = Destination.new(id, Destination.direction_in(), Destination.single(), "myapp")

      path = Path.join(System.tmp_dir!(), "test_ratchets_#{:erlang.unique_integer([:positive])}")

      on_exit(fn ->
        File.rm(path)
        File.rm(path <> ".tmp")
      end)

      dest = Destination.enable_ratchets(dest, path)
      dest = Destination.rotate_ratchets(dest)
      assert length(dest.ratchets) == 1
      assert byte_size(hd(dest.ratchets)) == 32
    end

    test "rotate_ratchets respects interval" do
      id = Identity.new()
      dest = Destination.new(id, Destination.direction_in(), Destination.single(), "myapp")

      path = Path.join(System.tmp_dir!(), "test_ratchets_#{:erlang.unique_integer([:positive])}")

      on_exit(fn ->
        File.rm(path)
        File.rm(path <> ".tmp")
      end)

      dest = Destination.enable_ratchets(dest, path)
      dest = Destination.rotate_ratchets(dest)
      count1 = length(dest.ratchets)

      # Second rotation within interval should not add
      dest = Destination.rotate_ratchets(dest)
      assert length(dest.ratchets) == count1
    end

    test "enforce_ratchets sets flag" do
      id = Identity.new()
      dest = Destination.new(id, Destination.direction_in(), Destination.single(), "myapp")

      path = Path.join(System.tmp_dir!(), "test_ratchets_#{:erlang.unique_integer([:positive])}")

      on_exit(fn ->
        File.rm(path)
        File.rm(path <> ".tmp")
      end)

      dest = Destination.enable_ratchets(dest, path)
      dest = Destination.enforce_ratchets(dest)
      assert dest.enforce_ratchets == true
    end

    test "enforce_ratchets does nothing without ratchets enabled" do
      id = Identity.new()
      dest = Destination.new(id, Destination.direction_in(), Destination.single(), "myapp")
      dest = Destination.enforce_ratchets(dest)
      assert dest.enforce_ratchets == false
    end

    test "set_retained_ratchets updates count" do
      id = Identity.new()
      dest = Destination.new(id, Destination.direction_in(), Destination.single(), "myapp")
      dest = Destination.set_retained_ratchets(dest, 100)
      assert dest.retained_ratchets == 100
    end

    test "set_ratchet_interval updates interval" do
      id = Identity.new()
      dest = Destination.new(id, Destination.direction_in(), Destination.single(), "myapp")
      dest = Destination.set_ratchet_interval(dest, 60)
      assert dest.ratchet_interval == 60
    end

    test "rotate_ratchets raises when ratchets not enabled" do
      id = Identity.new()
      dest = Destination.new(id, Destination.direction_in(), Destination.single(), "myapp")

      assert_raise RuntimeError, ~r/ratchets are not enabled/i, fn ->
        Destination.rotate_ratchets(dest)
      end
    end

    test "ratchet persistence roundtrip" do
      id = Identity.new()
      dest = Destination.new(id, Destination.direction_in(), Destination.single(), "myapp")

      path = Path.join(System.tmp_dir!(), "test_ratchets_#{:erlang.unique_integer([:positive])}")

      on_exit(fn ->
        File.rm(path)
        File.rm(path <> ".tmp")
      end)

      dest = Destination.enable_ratchets(dest, path)
      dest = Destination.rotate_ratchets(dest)
      ratchet = hd(dest.ratchets)

      # Re-enable (reload) from same path
      dest2 = Destination.new(id, Destination.direction_in(), Destination.single(), "myapp2")
      dest2 = Destination.enable_ratchets(dest2, path)
      assert length(dest2.ratchets) == 1
      assert hd(dest2.ratchets) == ratchet
    end
  end

  describe "announce with ratchets" do
    test "announce includes ratchet when enabled" do
      id = Identity.new()
      dest = Destination.new(id, Destination.direction_in(), Destination.single(), "myapp")

      path = Path.join(System.tmp_dir!(), "test_ratchets_#{:erlang.unique_integer([:positive])}")

      on_exit(fn ->
        File.rm(path)
        File.rm(path <> ".tmp")
      end)

      dest = Destination.enable_ratchets(dest, path)

      {packet, dest} = Destination.announce(dest, send: false)

      # With ratchet: pub_key (64) + name_hash (10) + random_hash (10) + ratchet (32) + signature (64) = 180
      assert byte_size(packet.data) >= 180
      assert packet.context_flag == RNS.Packet.flag_set()
      assert dest.ratchets != []
    end

    test "announce stores ratchet in identity store" do
      id = Identity.new()
      dest = Destination.new(id, Destination.direction_in(), Destination.single(), "myapp")

      path = Path.join(System.tmp_dir!(), "test_ratchets_#{:erlang.unique_integer([:positive])}")

      on_exit(fn ->
        File.rm(path)
        File.rm(path <> ".tmp")
      end)

      dest = Destination.enable_ratchets(dest, path)
      {_packet, _dest} = Destination.announce(dest, send: false)

      ratchet = Identity.ratchet(dest.hash)
      assert ratchet != nil
      assert byte_size(ratchet) == 32
    end
  end

  describe "SINGLE encrypt/decrypt with ratchets" do
    test "encrypt uses ratchet when available" do
      id = Identity.new()
      dest = Destination.new(id, Destination.direction_in(), Destination.single(), "myapp")

      path = Path.join(System.tmp_dir!(), "test_ratchets_#{:erlang.unique_integer([:positive])}")

      on_exit(fn ->
        File.rm(path)
        File.rm(path <> ".tmp")
      end)

      dest = Destination.enable_ratchets(dest, path)
      {_packet, dest} = Destination.announce(dest, send: false)

      plaintext = "ratchet encrypted data"
      ciphertext = Destination.encrypt(dest, plaintext)

      result = Destination.decrypt(dest, ciphertext)
      assert result == plaintext
    end
  end

  # ── Announce with send: true (end-to-end through Transport) ────

  describe "announce/2 — send: true (end-to-end)" do
    setup do
      RNS.Test.SupervisedHelpers.clear_transport_tables()
      :ok
    end

    test "announce transmits through a registered interface" do
      test_pid = self()

      iface = %{
        name: "AnnounceTestIface",
        hash: RNS.Cryptography.Hashes.truncated_hash("AnnounceTestIface"),
        online: true,
        out: true,
        bitrate: 1_000_000,
        process_outgoing: fn raw -> send(test_pid, {:announce_sent, raw}) end
      }

      RNS.Transport.register_interface(iface)

      id = Identity.new()
      dest = Destination.new(id, Destination.direction_in(), Destination.single(), "announcetest")

      {result, updated_dest} = Destination.announce(dest)

      # Result is nil (no receipt for announce packets) — successful send
      assert result == nil
      assert updated_dest.type == Destination.single()
      assert_receive {:announce_sent, raw}
      assert is_binary(raw)
      assert byte_size(raw) > 0
    end

    test "announce returns false when no interfaces are registered" do
      id = Identity.new()
      dest = Destination.new(id, Destination.direction_in(), Destination.single(), "announcetest")

      {result, _dest} = Destination.announce(dest)
      assert result == false
    end

    test "announce packet is routed as broadcast (bypasses path table)" do
      test_pid = self()

      iface1 = %{
        name: "BcastIface1",
        hash: RNS.Cryptography.Hashes.truncated_hash("BcastIface1"),
        online: true,
        out: true,
        bitrate: 1_000_000,
        process_outgoing: fn raw -> send(test_pid, {:bcast1, raw}) end
      }

      iface2 = %{
        name: "BcastIface2",
        hash: RNS.Cryptography.Hashes.truncated_hash("BcastIface2"),
        online: true,
        out: true,
        bitrate: 1_000_000,
        process_outgoing: fn raw -> send(test_pid, {:bcast2, raw}) end
      }

      RNS.Transport.register_interface(iface1)
      RNS.Transport.register_interface(iface2)

      id = Identity.new()
      dest = Destination.new(id, Destination.direction_in(), Destination.single(), "bcasttest")

      {_result, _dest} = Destination.announce(dest)

      # Announce should be broadcast to both interfaces
      assert_receive {:bcast1, _raw}
      assert_receive {:bcast2, _raw}
    end

    test "announce raw bytes can be unpacked as a valid announce packet" do
      test_pid = self()

      iface = %{
        name: "UnpackIface",
        hash: RNS.Cryptography.Hashes.truncated_hash("UnpackIface"),
        online: true,
        out: true,
        bitrate: 1_000_000,
        process_outgoing: fn raw -> send(test_pid, {:unpacked, raw}) end
      }

      RNS.Transport.register_interface(iface)

      id = Identity.new()
      dest = Destination.new(id, Destination.direction_in(), Destination.single(), "unpacktest")

      {_result, _dest} = Destination.announce(dest)

      assert_receive {:unpacked, raw}

      # Unpack and verify structure
      received_packet = RNS.Packet.new(nil, raw) |> RNS.Packet.unpack()
      assert received_packet.packet_type == RNS.Packet.announce()
      assert received_packet.destination_hash == dest.hash
      assert received_packet.destination_type == Destination.single()
    end

    test "announce with app_data transmits correctly" do
      test_pid = self()

      iface = %{
        name: "AppDataIface",
        hash: RNS.Cryptography.Hashes.truncated_hash("AppDataIface"),
        online: true,
        out: true,
        bitrate: 1_000_000,
        process_outgoing: fn raw -> send(test_pid, {:appdata_sent, raw}) end
      }

      RNS.Transport.register_interface(iface)

      id = Identity.new()
      dest = Destination.new(id, Destination.direction_in(), Destination.single(), "appdatatest")

      {_result, _dest} = Destination.announce(dest, app_data: "test app data")

      assert_receive {:appdata_sent, raw}

      received_packet = RNS.Packet.new(nil, raw) |> RNS.Packet.unpack()
      assert received_packet.packet_type == RNS.Packet.announce()

      # The announce data should include the app_data
      # pub_key (64) + name_hash (10) + random_hash (10) + signature (64) + app_data (13) = 161
      assert byte_size(received_packet.data) == 148 + byte_size("test app data")
    end

    test "announce with path_response context transmits correctly" do
      test_pid = self()

      iface = %{
        name: "PathRespIface",
        hash: RNS.Cryptography.Hashes.truncated_hash("PathRespIface"),
        online: true,
        out: true,
        bitrate: 1_000_000,
        process_outgoing: fn raw -> send(test_pid, {:pathresp_sent, raw}) end
      }

      RNS.Transport.register_interface(iface)

      id = Identity.new()
      dest = Destination.new(id, Destination.direction_in(), Destination.single(), "pathresptest")

      {_result, _dest} = Destination.announce(dest, path_response: true)

      assert_receive {:pathresp_sent, raw}

      received_packet = RNS.Packet.new(nil, raw) |> RNS.Packet.unpack()
      assert received_packet.packet_type == RNS.Packet.announce()
      assert received_packet.context == RNS.Packet.context_path_response()
    end
  end

  describe "register/1 and deregister/1" do
    setup do
      RNS.Test.SupervisedHelpers.clear_transport_tables()
      :ok
    end

    test "new/5 auto-registers IN destinations with Transport" do
      id = Identity.new()
      dest = Destination.new(id, Destination.direction_in(), Destination.single(), "autoregtest")

      assert RNS.Transport.destination_registered?(dest.hash)
      registered = RNS.Transport.get_destinations()
      assert Enum.any?(registered, fn d -> d.hash == dest.hash end)
    end

    test "new/5 auto-registers OUT destinations with Transport" do
      id = Identity.new()
      dest = Destination.new(id, Destination.direction_out(), Destination.single(), "outregtest")

      assert RNS.Transport.destination_registered?(dest.hash)
    end

    test "new/5 auto-registers PLAIN destinations with Transport" do
      dest = Destination.new(nil, Destination.direction_in(), Destination.plain(), "plainregtest")

      assert RNS.Transport.destination_registered?(dest.hash)
    end

    test "deregister/1 removes destination from Transport" do
      id = Identity.new()
      dest = Destination.new(id, Destination.direction_in(), Destination.single(), "deregtest")

      assert RNS.Transport.destination_registered?(dest.hash)

      Destination.deregister(dest)
      refute RNS.Transport.destination_registered?(dest.hash)
    end

    test "register/1 can re-register a deregistered destination" do
      id = Identity.new()
      dest = Destination.new(id, Destination.direction_in(), Destination.single(), "reregtest")

      Destination.deregister(dest)
      refute RNS.Transport.destination_registered?(dest.hash)

      assert :ok == Destination.register(dest)
      assert RNS.Transport.destination_registered?(dest.hash)
    end

    test "get_destinations/0 returns all registered destinations" do
      id1 = Identity.new()
      id2 = Identity.new()
      dest1 = Destination.new(id1, Destination.direction_in(), Destination.single(), "getdest1")
      dest2 = Destination.new(id2, Destination.direction_in(), Destination.single(), "getdest2")

      destinations = RNS.Transport.get_destinations()
      hashes = Enum.map(destinations, & &1.hash)

      assert dest1.hash in hashes
      assert dest2.hash in hashes
    end
  end
end
