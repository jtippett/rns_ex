defmodule RNS.ReticulumTest do
  use ExUnit.Case, async: false

  alias RNS.Reticulum
  alias RNS.Vendor.ConfigObj
  alias RNS.Vendor.ConfigObj.Section

  # ── Constants ──────────────────────────────────────────────────────────

  describe "constants" do
    test "MTU is 500" do
      assert Reticulum.mtu() == 500
    end

    test "link MTU discovery default is true" do
      assert Reticulum.link_mtu_discovery_default() == true
    end

    test "max queued announces is 16384" do
      assert Reticulum.max_queued_announces() == 16_384
    end

    test "queued announce life is 24 hours" do
      assert Reticulum.queued_announce_life() == 86_400
    end

    test "announce cap is 2%" do
      assert Reticulum.announce_cap() == 2
    end

    test "minimum bitrate is 5 bps" do
      assert Reticulum.minimum_bitrate() == 5
    end

    test "default per hop timeout is 6 seconds" do
      assert Reticulum.default_per_hop_timeout() == 6
    end

    test "truncated hash length is 128 bits" do
      assert Reticulum.truncated_hashlength() == 128
    end

    test "header minsize is 19 bytes" do
      # 2 + 1 + (128/8)*1 = 2 + 1 + 16 = 19
      assert Reticulum.header_minsize() == 19
    end

    test "header maxsize is 35 bytes" do
      # 2 + 1 + (128/8)*2 = 2 + 1 + 32 = 35
      assert Reticulum.header_maxsize() == 35
    end

    test "IFAC min size is 1" do
      assert Reticulum.ifac_min_size() == 1
    end

    test "IFAC salt is the correct 32-byte value" do
      expected =
        Base.decode16!("ADF54D882C9A9B80771EB4995D702D4A3E733391B2A0F53F416D9F907E55CFF8",
          case: :upper
        )

      assert Reticulum.ifac_salt() == expected
      assert byte_size(Reticulum.ifac_salt()) == 32
    end

    test "MDU is MTU - HEADER_MAXSIZE - IFAC_MIN_SIZE" do
      assert Reticulum.mdu() == 500 - 35 - 1
      assert Reticulum.mdu() == 464
    end

    test "resource cache is 24 hours" do
      assert Reticulum.resource_cache() == 86_400
    end

    test "job interval is 5 minutes" do
      assert Reticulum.job_interval() == 300
    end

    test "clean interval is 15 minutes" do
      assert Reticulum.clean_interval() == 900
    end

    test "persist interval is 12 hours" do
      assert Reticulum.persist_interval() == 43_200
    end

    test "gracious persist interval is 5 minutes" do
      assert Reticulum.gracious_persist_interval() == 300
    end
  end

  # ── Path Computation ───────────────────────────────────────────────────

  describe "compute_paths/1" do
    test "computes all paths from configdir" do
      paths = Reticulum.compute_paths("/tmp/test_reticulum")

      assert paths.configdir == "/tmp/test_reticulum"
      assert paths.configpath == "/tmp/test_reticulum/config"
      assert paths.storagepath == "/tmp/test_reticulum/storage"
      assert paths.cachepath == "/tmp/test_reticulum/storage/cache"
      assert paths.resourcepath == "/tmp/test_reticulum/storage/resources"
      assert paths.identitypath == "/tmp/test_reticulum/storage/identities"
      assert paths.blackholepath == "/tmp/test_reticulum/storage/blackhole"
      assert paths.interfacepath == "/tmp/test_reticulum/interfaces"
    end
  end

  # ── Directory Detection ────────────────────────────────────────────────

  describe "determine_configdir/1" do
    test "uses custom configdir when provided" do
      assert Reticulum.determine_configdir("/custom/path") == "/custom/path"
    end

    test "falls back to ~/.reticulum when no standard dirs exist" do
      # On a clean system, /etc/reticulum won't exist, so it should fall back
      result = Reticulum.determine_configdir(nil)
      assert is_binary(result)

      assert String.ends_with?(result, ".reticulum") or
               String.contains?(result, "reticulum")
    end
  end

  # ── Directory Ensurance ────────────────────────────────────────────────

  describe "ensure_directories/1" do
    test "creates all required directories" do
      tmpdir = System.tmp_dir!()
      configdir = Path.join(tmpdir, "rns_test_dirs_#{:rand.uniform(100_000)}")
      paths = Reticulum.compute_paths(configdir)

      on_exit(fn -> File.rm_rf!(configdir) end)

      assert Reticulum.ensure_directories(paths) == :ok

      assert File.dir?(paths.storagepath)
      assert File.dir?(paths.cachepath)
      assert File.dir?(paths.resourcepath)
      assert File.dir?(paths.identitypath)
      assert File.dir?(paths.blackholepath)
      assert File.dir?(paths.interfacepath)
      assert File.dir?(Path.join(paths.cachepath, "announces"))
    end
  end

  # ── Default Config ─────────────────────────────────────────────────────

  describe "default_config/0" do
    test "returns a parseable config string" do
      config_text = Reticulum.default_config()
      assert is_binary(config_text)

      {:ok, config} = ConfigObj.parse(config_text)
      assert Section.has_key?(config, "reticulum")
      assert Section.has_key?(config, "logging")
      assert Section.has_key?(config, "interfaces")
    end

    test "default config has expected values" do
      {:ok, config} = ConfigObj.parse(Reticulum.default_config())

      ret = Section.get(config, "reticulum")
      assert Section.as_bool(ret, "enable_transport") == false
      assert Section.as_bool(ret, "share_instance") == true
      assert Section.get(ret, "instance_name") == "default"

      logging = Section.get(config, "logging")
      assert Section.as_int(logging, "loglevel") == 4
    end
  end

  describe "create_default_config/2" do
    test "creates config file on disk" do
      tmpdir = System.tmp_dir!()
      configdir = Path.join(tmpdir, "rns_test_defconfig_#{:rand.uniform(100_000)}")
      configpath = Path.join(configdir, "config")

      on_exit(fn -> File.rm_rf!(configdir) end)

      assert {:ok, config} = Reticulum.create_default_config(configdir, configpath)
      assert File.regular?(configpath)
      assert Section.has_key?(config, "reticulum")
    end
  end

  # ── Config Application ─────────────────────────────────────────────────

  describe "apply_config/2" do
    test "applies default config" do
      {:ok, config} = ConfigObj.parse(Reticulum.default_config())
      result = Reticulum.apply_config(config)

      assert result.transport_enabled == false
      assert result.share_instance == true
      assert result.use_implicit_proof == true
      assert result.allow_probes == false
      assert result.link_mtu_discovery == true
      assert result.remote_management_enabled == false
      assert result.panic_on_interface_error == false
      assert result.local_interface_port == 37428
      assert result.local_control_port == 37429
    end

    test "applies transport enabled" do
      {:ok, config} =
        ConfigObj.parse("""
        [reticulum]
        enable_transport = yes
        """)

      result = Reticulum.apply_config(config)
      assert result.transport_enabled == true
    end

    test "applies share_instance = no" do
      {:ok, config} =
        ConfigObj.parse("""
        [reticulum]
        share_instance = no
        """)

      result = Reticulum.apply_config(config)
      assert result.share_instance == false
    end

    test "applies custom ports" do
      {:ok, config} =
        ConfigObj.parse("""
        [reticulum]
        shared_instance_port = 55905
        instance_control_port = 55906
        """)

      result = Reticulum.apply_config(config)
      assert result.local_interface_port == 55905
      assert result.local_control_port == 55906
    end

    test "applies use_implicit_proof = false" do
      {:ok, config} =
        ConfigObj.parse("""
        [reticulum]
        use_implicit_proof = false
        """)

      result = Reticulum.apply_config(config)
      assert result.use_implicit_proof == false
    end

    test "applies respond_to_probes" do
      {:ok, config} =
        ConfigObj.parse("""
        [reticulum]
        respond_to_probes = yes
        """)

      result = Reticulum.apply_config(config)
      assert result.allow_probes == true
    end

    test "applies panic_on_interface_error" do
      {:ok, config} =
        ConfigObj.parse("""
        [reticulum]
        panic_on_interface_error = yes
        """)

      result = Reticulum.apply_config(config)
      assert result.panic_on_interface_error == true
    end

    test "applies link_mtu_discovery = false" do
      {:ok, config} =
        ConfigObj.parse("""
        [reticulum]
        link_mtu_discovery = false
        """)

      result = Reticulum.apply_config(config)
      assert result.link_mtu_discovery == false
    end

    test "applies enable_remote_management" do
      {:ok, config} =
        ConfigObj.parse("""
        [reticulum]
        enable_remote_management = yes
        """)

      result = Reticulum.apply_config(config)
      assert result.remote_management_enabled == true
    end

    test "applies discover_interfaces" do
      {:ok, config} =
        ConfigObj.parse("""
        [reticulum]
        discover_interfaces = yes
        """)

      result = Reticulum.apply_config(config)
      assert result.discover_interfaces == true
    end

    test "applies required_discovery_value" do
      {:ok, config} =
        ConfigObj.parse("""
        [reticulum]
        required_discovery_value = 5
        """)

      result = Reticulum.apply_config(config)
      assert result.required_discovery_value == 5
    end

    test "required_discovery_value 0 maps to nil" do
      {:ok, config} =
        ConfigObj.parse("""
        [reticulum]
        required_discovery_value = 0
        """)

      result = Reticulum.apply_config(config)
      assert result.required_discovery_value == nil
    end

    test "applies publish_blackhole" do
      {:ok, config} =
        ConfigObj.parse("""
        [reticulum]
        publish_blackhole = yes
        """)

      result = Reticulum.apply_config(config)
      assert result.publish_blackhole == true
    end

    test "applies blackhole_sources" do
      {:ok, config} =
        ConfigObj.parse("""
        [reticulum]
        blackhole_sources = 521c87a83afb8f29e4455e77930b973b
        """)

      result = Reticulum.apply_config(config)
      assert length(result.blackhole_sources) == 1

      assert hd(result.blackhole_sources) ==
               Base.decode16!("521c87a83afb8f29e4455e77930b973b", case: :lower)
    end

    test "applies autoconnect_discovered_interfaces" do
      {:ok, config} =
        ConfigObj.parse("""
        [reticulum]
        autoconnect_discovered_interfaces = 3
        """)

      result = Reticulum.apply_config(config)
      assert result.autoconnect_discovered_interfaces == 3
    end

    test "applies force_shared_instance_bitrate" do
      {:ok, config} =
        ConfigObj.parse("""
        [reticulum]
        force_shared_instance_bitrate = 115200
        """)

      result = Reticulum.apply_config(config)
      assert result.force_shared_instance_bitrate == 115_200
    end

    test "applies shared_instance_type = tcp" do
      {:ok, config} =
        ConfigObj.parse("""
        [reticulum]
        shared_instance_type = tcp
        """)

      result = Reticulum.apply_config(config)
      assert result.shared_instance_type == "tcp"
    end

    test "applies rpc_key" do
      {:ok, config} =
        ConfigObj.parse("""
        [reticulum]
        rpc_key = deadbeefcafebabe1234567890abcdef
        """)

      result = Reticulum.apply_config(config)
      assert result.rpc_key == Base.decode16!("deadbeefcafebabe1234567890abcdef", case: :lower)
    end

    test "invalid rpc_key falls back to nil" do
      {:ok, config} =
        ConfigObj.parse("""
        [reticulum]
        rpc_key = not_valid_hex_here
        """)

      result = Reticulum.apply_config(config)
      assert result.rpc_key == nil
    end
  end

  # ── Logging Config ─────────────────────────────────────────────────────

  describe "apply_logging_config/4" do
    test "applies loglevel from config when no override" do
      {:ok, config} =
        ConfigObj.parse("""
        [logging]
        loglevel = 6
        """)

      state = %{}
      result = Reticulum.apply_logging_config(config, state, nil, nil)
      assert result.loglevel == 6
    end

    test "applies verbosity addition" do
      {:ok, config} =
        ConfigObj.parse("""
        [logging]
        loglevel = 4
        """)

      state = %{}
      result = Reticulum.apply_logging_config(config, state, nil, 2)
      assert result.loglevel == 6
    end

    test "clamps loglevel to 0-7 range" do
      {:ok, config} =
        ConfigObj.parse("""
        [logging]
        loglevel = 5
        """)

      state = %{}
      result = Reticulum.apply_logging_config(config, state, nil, 10)
      assert result.loglevel == 7
    end

    test "skips config loglevel when requested_loglevel provided" do
      {:ok, config} =
        ConfigObj.parse("""
        [logging]
        loglevel = 6
        """)

      state = %{}
      result = Reticulum.apply_logging_config(config, state, 3, nil)
      # Should not set loglevel from config when requested_loglevel is given
      refute Map.has_key?(result, :loglevel)
    end

    test "handles missing logging section" do
      {:ok, config} =
        ConfigObj.parse("""
        [reticulum]
        enable_transport = no
        """)

      state = %{some: :data}
      result = Reticulum.apply_logging_config(config, state, nil, nil)
      assert result == state
    end
  end

  # ── Test Config File Compatibility ─────────────────────────────────────

  describe "test config compatibility" do
    test "parses python test config" do
      config_path = Path.join([File.cwd!(), "python", "tests", "rnsconfig", "config"])

      if File.regular?(config_path) do
        {:ok, config} = ConfigObj.parse_file(config_path)
        result = Reticulum.apply_config(config)

        assert result.transport_enabled == false
        assert result.share_instance == true
        assert result.local_interface_port == 55905
        assert result.local_control_port == 55906
        assert result.panic_on_interface_error == false
      end
    end
  end

  # ── GenServer Integration ──────────────────────────────────────────────

  describe "GenServer start_link" do
    setup do
      tmpdir = System.tmp_dir!()
      configdir = Path.join(tmpdir, "rns_test_genserver_#{:rand.uniform(100_000)}")
      on_exit(fn -> File.rm_rf!(configdir) end)
      {:ok, configdir: configdir}
    end

    test "starts with custom configdir and creates default config", %{configdir: configdir} do
      name = :"test_reticulum_#{:rand.uniform(100_000)}"

      {:ok, pid} =
        Reticulum.start_link(
          configdir: configdir,
          skip_start: true,
          server_name: name
        )

      assert Process.alive?(pid)

      state = GenServer.call(name, :get_state)
      assert state.configdir == configdir
      assert state.configpath == Path.join(configdir, "config")
      assert File.regular?(state.configpath)

      GenServer.stop(pid)
    end

    test "creates all storage directories", %{configdir: configdir} do
      name = :"test_reticulum_dirs_#{:rand.uniform(100_000)}"

      {:ok, pid} =
        Reticulum.start_link(
          configdir: configdir,
          skip_start: true,
          server_name: name
        )

      state = GenServer.call(name, :get_state)
      assert File.dir?(state.storagepath)
      assert File.dir?(state.cachepath)
      assert File.dir?(state.resourcepath)
      assert File.dir?(state.identitypath)
      assert File.dir?(state.blackholepath)
      assert File.dir?(state.interfacepath)
      assert File.dir?(Path.join(state.cachepath, "announces"))

      GenServer.stop(pid)
    end

    test "loads existing config file", %{configdir: configdir} do
      name = :"test_reticulum_load_#{:rand.uniform(100_000)}"

      # Create config dir and file manually
      File.mkdir_p!(configdir)

      File.write!(Path.join(configdir, "config"), """
      [reticulum]
      enable_transport = yes
      shared_instance_port = 45000
      use_implicit_proof = false

      [logging]
      loglevel = 6
      """)

      {:ok, pid} =
        Reticulum.start_link(
          configdir: configdir,
          skip_start: true,
          server_name: name
        )

      state = GenServer.call(name, :get_state)
      assert state.transport_enabled == true
      assert state.local_interface_port == 45_000
      assert state.use_implicit_proof == false

      GenServer.stop(pid)
    end

    test "query functions work through GenServer", %{configdir: configdir} do
      name = :"test_reticulum_query_#{:rand.uniform(100_000)}"

      File.mkdir_p!(configdir)

      File.write!(Path.join(configdir, "config"), """
      [reticulum]
      enable_transport = yes
      respond_to_probes = yes
      publish_blackhole = yes

      [logging]
      loglevel = 3
      """)

      {:ok, pid} =
        Reticulum.start_link(
          configdir: configdir,
          skip_start: true,
          server_name: name
        )

      assert GenServer.call(name, :transport_enabled?) == true
      assert GenServer.call(name, :probe_destination_enabled?) == true
      assert GenServer.call(name, :publish_blackhole_enabled?) == true
      assert GenServer.call(name, :should_use_implicit_proof?) == true
      assert GenServer.call(name, :link_mtu_discovery?) == true
      assert GenServer.call(name, :remote_management_enabled?) == false
      assert GenServer.call(name, :required_discovery_value) == nil
      assert GenServer.call(name, :blackhole_sources) == []
      assert GenServer.call(name, :interface_discovery_sources) == []
      assert GenServer.call(name, :discover_interfaces?) == false
      assert GenServer.call(name, :is_shared_instance?) == false
      assert GenServer.call(name, :is_standalone_instance?) == false
      assert GenServer.call(name, :is_connected_to_shared_instance?) == false

      GenServer.stop(pid)
    end

    test "returns config via get_config", %{configdir: configdir} do
      name = :"test_reticulum_config_#{:rand.uniform(100_000)}"

      {:ok, pid} =
        Reticulum.start_link(
          configdir: configdir,
          skip_start: true,
          server_name: name
        )

      config = GenServer.call(name, :get_config)
      assert %Section{} = config
      assert Section.has_key?(config, "reticulum")

      GenServer.stop(pid)
    end

    test "handles should_persist_data cast", %{configdir: configdir} do
      name = :"test_reticulum_persist_#{:rand.uniform(100_000)}"

      {:ok, pid} =
        Reticulum.start_link(
          configdir: configdir,
          skip_start: true,
          server_name: name
        )

      # Should not crash
      GenServer.cast(name, :should_persist_data)
      # Give time for async processing
      Process.sleep(50)
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end

    test "handles run_jobs message", %{configdir: configdir} do
      name = :"test_reticulum_jobs_#{:rand.uniform(100_000)}"

      {:ok, pid} =
        Reticulum.start_link(
          configdir: configdir,
          skip_start: true,
          server_name: name
        )

      # Manually send run_jobs to test periodic job handler
      send(pid, :run_jobs)
      Process.sleep(50)
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end

    test "terminate persists data gracefully", %{configdir: configdir} do
      name = :"test_reticulum_terminate_#{:rand.uniform(100_000)}"

      {:ok, pid} =
        Reticulum.start_link(
          configdir: configdir,
          skip_start: true,
          server_name: name
        )

      # Should stop cleanly without crash
      GenServer.stop(pid)
      refute Process.alive?(pid)
    end

    test "handles unknown messages gracefully", %{configdir: configdir} do
      name = :"test_reticulum_unknown_#{:rand.uniform(100_000)}"

      {:ok, pid} =
        Reticulum.start_link(
          configdir: configdir,
          skip_start: true,
          server_name: name
        )

      send(pid, :some_random_message)
      Process.sleep(50)
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end
  end

  # ── Cache Cleaning ─────────────────────────────────────────────────────

  describe "cache cleaning" do
    test "cleans old files from resource cache" do
      tmpdir = System.tmp_dir!()
      configdir = Path.join(tmpdir, "rns_test_cache_clean_#{:rand.uniform(100_000)}")
      paths = Reticulum.compute_paths(configdir)
      Reticulum.ensure_directories(paths)

      on_exit(fn -> File.rm_rf!(configdir) end)

      # Create a file with a hash-like name (64 hex chars = 32 bytes = 256 bits)
      hash_name = String.duplicate("ab", 32)
      filepath = Path.join(paths.resourcepath, hash_name)
      File.write!(filepath, "test data")

      # File exists
      assert File.regular?(filepath)

      # Start instance and trigger job — the file is fresh so it shouldn't be cleaned
      name = :"test_reticulum_cache_#{:rand.uniform(100_000)}"

      {:ok, pid} =
        Reticulum.start_link(
          configdir: configdir,
          skip_start: true,
          server_name: name
        )

      # Trigger run_jobs — since last_cache_clean starts at 0, clean_interval
      # will have passed and cleaning will run. But the file is fresh.
      send(pid, :run_jobs)
      Process.sleep(100)
      assert File.regular?(filepath)

      GenServer.stop(pid)
    end
  end

  # ── Config Edge Cases ──────────────────────────────────────────────────

  describe "config edge cases" do
    test "handles empty config" do
      {:ok, config} = ConfigObj.parse("")
      result = Reticulum.apply_config(config)

      # Should use all defaults
      assert result.transport_enabled == false
      assert result.share_instance == true
      assert result.use_implicit_proof == true
    end

    test "handles config with only logging section" do
      {:ok, config} =
        ConfigObj.parse("""
        [logging]
        loglevel = 2
        """)

      result = Reticulum.apply_config(config)
      assert result.transport_enabled == false
      assert result.share_instance == true
    end

    test "handles config with only reticulum section" do
      {:ok, config} =
        ConfigObj.parse("""
        [reticulum]
        enable_transport = yes
        """)

      result = Reticulum.apply_config(config)
      assert result.transport_enabled == true
    end

    test "multiple blackhole sources" do
      {:ok, config} =
        ConfigObj.parse("""
        [reticulum]
        blackhole_sources = 521c87a83afb8f29e4455e77930b973b, a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6
        """)

      result = Reticulum.apply_config(config)
      assert length(result.blackhole_sources) == 2
    end

    test "raises on invalid hash length in blackhole_sources" do
      {:ok, config} =
        ConfigObj.parse("""
        [reticulum]
        blackhole_sources = tooshort
        """)

      assert_raise RuntimeError, ~r/invalid/, fn ->
        Reticulum.apply_config(config)
      end
    end
  end

  # ── Path Accessors via GenServer ───────────────────────────────────────

  describe "path accessors" do
    setup do
      tmpdir = System.tmp_dir!()
      configdir = Path.join(tmpdir, "rns_test_paths_#{:rand.uniform(100_000)}")
      name = :"test_reticulum_paths_#{:rand.uniform(100_000)}"

      {:ok, pid} =
        Reticulum.start_link(
          configdir: configdir,
          skip_start: true,
          server_name: name
        )

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
        File.rm_rf!(configdir)
      end)

      {:ok, name: name, configdir: configdir}
    end

    test "configdir returns correct path", %{name: name, configdir: configdir} do
      assert GenServer.call(name, :configdir) == configdir
    end

    test "configpath returns correct path", %{name: name, configdir: configdir} do
      assert GenServer.call(name, :configpath) == Path.join(configdir, "config")
    end

    test "storagepath returns correct path", %{name: name, configdir: configdir} do
      assert GenServer.call(name, :storagepath) == Path.join(configdir, "storage")
    end

    test "cachepath returns correct path", %{name: name, configdir: configdir} do
      assert GenServer.call(name, :cachepath) == Path.join([configdir, "storage", "cache"])
    end

    test "resourcepath returns correct path", %{name: name, configdir: configdir} do
      assert GenServer.call(name, :resourcepath) == Path.join([configdir, "storage", "resources"])
    end

    test "identitypath returns correct path", %{name: name, configdir: configdir} do
      assert GenServer.call(name, :identitypath) ==
               Path.join([configdir, "storage", "identities"])
    end

    test "blackholepath returns correct path", %{name: name, configdir: configdir} do
      assert GenServer.call(name, :blackholepath) ==
               Path.join([configdir, "storage", "blackhole"])
    end

    test "interfacepath returns correct path", %{name: name, configdir: configdir} do
      assert GenServer.call(name, :interfacepath) == Path.join(configdir, "interfaces")
    end
  end

  # ── Interface Mode Parsing ───────────────────────────────────────────

  describe "parse_interface_mode (via synthesize_interface)" do
    test "parses all interface mode strings" do
      alias RNS.Interfaces.Interface

      modes = %{
        "full" => Interface.mode_full(),
        "access_point" => Interface.mode_access_point(),
        "accesspoint" => Interface.mode_access_point(),
        "ap" => Interface.mode_access_point(),
        "pointtopoint" => Interface.mode_point_to_point(),
        "ptp" => Interface.mode_point_to_point(),
        "roaming" => Interface.mode_roaming(),
        "boundary" => Interface.mode_boundary(),
        "gateway" => Interface.mode_gateway(),
        "gw" => Interface.mode_gateway()
      }

      for {mode_str, expected_mode} <- modes do
        section =
          Section.new()
          |> Section.put_scalar("type", "UDPInterface")
          |> Section.put_scalar("enabled", "yes")
          |> Section.put_scalar("interface_mode", mode_str)

        params = Reticulum.extract_interface_params(section, Interface.mode_full(), "test")

        assert params.interface_mode == expected_mode,
               "Mode '#{mode_str}' should be #{expected_mode}"
      end
    end

    test "defaults to full mode when no mode specified" do
      alias RNS.Interfaces.Interface

      section =
        Section.new()
        |> Section.put_scalar("type", "UDPInterface")
        |> Section.put_scalar("enabled", "yes")

      params = Reticulum.extract_interface_params(section, Interface.mode_full(), "test")
      assert params.interface_mode == Interface.mode_full()
    end
  end

  # ── Interface Parameter Extraction ──────────────────────────────────

  describe "extract_interface_params" do
    test "extracts IFAC settings" do
      section =
        Section.new()
        |> Section.put_scalar("type", "UDPInterface")
        |> Section.put_scalar("networkname", "mynet")
        |> Section.put_scalar("passphrase", "secret123")
        |> Section.put_scalar("ifac_size", "64")

      params = Reticulum.extract_interface_params(section, 0x00, "test")
      assert params.ifac_netname == "mynet"
      assert params.ifac_netkey == "secret123"
      assert params.ifac_size == 8
    end

    test "ignores ifac_size below minimum" do
      section =
        Section.new()
        |> Section.put_scalar("type", "UDPInterface")
        |> Section.put_scalar("ifac_size", "4")

      params = Reticulum.extract_interface_params(section, 0x00, "test")
      assert params.ifac_size == nil
    end

    test "extracts bitrate with minimum check" do
      section =
        Section.new()
        |> Section.put_scalar("type", "UDPInterface")
        |> Section.put_scalar("bitrate", "9600")

      params = Reticulum.extract_interface_params(section, 0x00, "test")
      assert params.configured_bitrate == 9600
    end

    test "ignores bitrate below minimum" do
      section =
        Section.new()
        |> Section.put_scalar("type", "UDPInterface")
        |> Section.put_scalar("bitrate", "2")

      params = Reticulum.extract_interface_params(section, 0x00, "test")
      assert params.configured_bitrate == nil
    end

    test "extracts announce rate parameters" do
      section =
        Section.new()
        |> Section.put_scalar("type", "UDPInterface")
        |> Section.put_scalar("announce_rate_target", "30")
        |> Section.put_scalar("announce_rate_grace", "5")
        |> Section.put_scalar("announce_rate_penalty", "10")

      params = Reticulum.extract_interface_params(section, 0x00, "test")
      assert params.announce_rate_target == 30
      assert params.announce_rate_grace == 5
      assert params.announce_rate_penalty == 10
    end

    test "defaults announce rate grace and penalty to 0 when target set" do
      section =
        Section.new()
        |> Section.put_scalar("type", "UDPInterface")
        |> Section.put_scalar("announce_rate_target", "60")

      params = Reticulum.extract_interface_params(section, 0x00, "test")
      assert params.announce_rate_target == 60
      assert params.announce_rate_grace == 0
      assert params.announce_rate_penalty == 0
    end

    test "extracts announce cap percentage" do
      section =
        Section.new()
        |> Section.put_scalar("type", "UDPInterface")
        |> Section.put_scalar("announce_cap", "5.0")

      params = Reticulum.extract_interface_params(section, 0x00, "test")
      assert_in_delta params.announce_cap, 0.05, 0.001
    end

    test "extracts bootstrap_only and outgoing" do
      section =
        Section.new()
        |> Section.put_scalar("type", "UDPInterface")
        |> Section.put_scalar("bootstrap_only", "true")
        |> Section.put_scalar("outgoing", "false")

      params = Reticulum.extract_interface_params(section, 0x00, "test")
      assert params.bootstrap_only == true
      assert params.outgoing == false
    end

    test "extracts ingress control parameters" do
      section =
        Section.new()
        |> Section.put_scalar("type", "UDPInterface")
        |> Section.put_scalar("ingress_control", "false")
        |> Section.put_scalar("ic_max_held_announces", "100")
        |> Section.put_scalar("ic_burst_hold", "30.0")

      params = Reticulum.extract_interface_params(section, 0x00, "test")
      assert params.ingress_control == false
      assert params.ic_max_held_announces == 100
      assert_in_delta params.ic_burst_hold, 30.0, 0.01
    end
  end

  # ── Discovery Parameters ─────────────────────────────────────────────

  describe "extract_discovery_params" do
    test "extracts discovery settings when discoverable" do
      section =
        Section.new()
        |> Section.put_scalar("type", "UDPInterface")
        |> Section.put_scalar("discoverable", "true")
        |> Section.put_scalar("announce_interval", "10")
        |> Section.put_scalar("discovery_name", "my_interface")
        |> Section.put_scalar("discovery_encrypt", "true")
        |> Section.put_scalar("latitude", "51.5074")
        |> Section.put_scalar("longitude", "-0.1278")

      alias RNS.Interfaces.Interface

      params =
        Reticulum.extract_interface_params(section, Interface.mode_full(), "TestIface")

      assert params.discoverable == true
      assert params.discovery_params.discovery_announce_interval == 10 * 60
      assert params.discovery_params.discovery_name == "my_interface"
      assert params.discovery_params.discovery_encrypt == true
      assert_in_delta params.discovery_params.latitude, 51.5074, 0.001
      assert_in_delta params.discovery_params.longitude, -0.1278, 0.001
    end

    test "enforces minimum announce interval of 5 minutes" do
      section =
        Section.new()
        |> Section.put_scalar("type", "UDPInterface")
        |> Section.put_scalar("discoverable", "true")
        |> Section.put_scalar("announce_interval", "1")

      params = Reticulum.extract_interface_params(section, 0x00, "test")
      assert params.discovery_params.discovery_announce_interval == 5 * 60
    end

    test "defaults announce interval to 6 hours" do
      section =
        Section.new()
        |> Section.put_scalar("type", "UDPInterface")
        |> Section.put_scalar("discoverable", "true")

      params = Reticulum.extract_interface_params(section, 0x00, "test")
      assert params.discovery_params.discovery_announce_interval == 6 * 60 * 60
    end

    test "auto-configures RNode to AP mode when discoverable" do
      alias RNS.Interfaces.Interface

      section =
        Section.new()
        |> Section.put_scalar("type", "RNodeInterface")
        |> Section.put_scalar("discoverable", "true")

      params =
        Reticulum.extract_interface_params(section, Interface.mode_full(), "TestRNode")

      assert params.interface_mode == Interface.mode_access_point()
    end

    test "auto-configures non-RNode to gateway mode when discoverable" do
      alias RNS.Interfaces.Interface

      section =
        Section.new()
        |> Section.put_scalar("type", "UDPInterface")
        |> Section.put_scalar("discoverable", "true")

      params =
        Reticulum.extract_interface_params(section, Interface.mode_full(), "TestUDP")

      assert params.interface_mode == Interface.mode_gateway()
    end

    test "preserves AP mode when discoverable" do
      alias RNS.Interfaces.Interface

      section =
        Section.new()
        |> Section.put_scalar("type", "UDPInterface")
        |> Section.put_scalar("discoverable", "true")

      params =
        Reticulum.extract_interface_params(section, Interface.mode_access_point(), "TestUDP")

      assert params.interface_mode == Interface.mode_access_point()
    end
  end

  # ── Config Key to Atom Mapping ───────────────────────────────────────

  describe "config_section_to_opts" do
    test "converts config section to keyword list with name" do
      section =
        Section.new()
        |> Section.put_scalar("type", "UDPInterface")
        |> Section.put_scalar("listen_ip", "0.0.0.0")
        |> Section.put_scalar("listen_port", "4242")
        |> Section.put_scalar("forward_ip", "255.255.255.255")
        |> Section.put_scalar("forward_port", "4242")

      params = %{configured_bitrate: nil}
      opts = Reticulum.config_section_to_opts(section, "My UDP", params)

      assert Keyword.get(opts, :name) == "My UDP"
      assert Keyword.get(opts, :type) == "UDPInterface"
      assert Keyword.get(opts, :listen_ip) == "0.0.0.0"
      assert Keyword.get(opts, :listen_port) == 4242
      assert Keyword.get(opts, :forward_ip) == "255.255.255.255"
      assert Keyword.get(opts, :forward_port) == 4242
    end

    test "maps 'remote' to target_host" do
      section =
        Section.new()
        |> Section.put_scalar("type", "BackboneInterface")
        |> Section.put_scalar("remote", "10.0.0.1")

      params = %{configured_bitrate: nil}
      opts = Reticulum.config_section_to_opts(section, "Backbone", params)

      assert Keyword.get(opts, :target_host) == "10.0.0.1"
    end

    test "includes configured_bitrate when present" do
      section =
        Section.new()
        |> Section.put_scalar("type", "UDPInterface")

      params = %{configured_bitrate: 115_200}
      opts = Reticulum.config_section_to_opts(section, "test", params)

      assert Keyword.get(opts, :configured_bitrate) == 115_200
    end
  end

  # ── Synthesize Interface ─────────────────────────────────────────────

  describe "synthesize_interface" do
    setup do
      tmpdir = System.tmp_dir!()
      configdir = Path.join(tmpdir, "rns_test_synth_#{:rand.uniform(100_000)}")
      on_exit(fn -> File.rm_rf!(configdir) end)
      {:ok, configdir: configdir}
    end

    test "skips disabled interface", %{configdir: configdir} do
      name = :"test_synth_disabled_#{:rand.uniform(100_000)}"

      {:ok, pid} =
        Reticulum.start_link(
          configdir: configdir,
          skip_start: true,
          server_name: name
        )

      state = GenServer.call(name, :get_state)

      section =
        Section.new()
        |> Section.put_scalar("type", "UDPInterface")
        |> Section.put_scalar("enabled", "no")

      new_state = Reticulum.synthesize_interface(state, section, "Disabled Interface")
      assert new_state.started_interfaces == state.started_interfaces

      GenServer.stop(pid)
    end

    test "skips interface with no enabled flag", %{configdir: configdir} do
      name = :"test_synth_noflag_#{:rand.uniform(100_000)}"

      {:ok, pid} =
        Reticulum.start_link(
          configdir: configdir,
          skip_start: true,
          server_name: name
        )

      state = GenServer.call(name, :get_state)

      section =
        Section.new()
        |> Section.put_scalar("type", "UDPInterface")

      new_state = Reticulum.synthesize_interface(state, section, "No Flag")
      assert new_state.started_interfaces == state.started_interfaces

      GenServer.stop(pid)
    end

    test "handles unknown interface type gracefully", %{configdir: configdir} do
      name = :"test_synth_unknown_#{:rand.uniform(100_000)}"

      {:ok, pid} =
        Reticulum.start_link(
          configdir: configdir,
          skip_start: true,
          server_name: name
        )

      state = GenServer.call(name, :get_state)

      section =
        Section.new()
        |> Section.put_scalar("type", "NonExistentInterface")
        |> Section.put_scalar("enabled", "yes")

      new_state = Reticulum.synthesize_interface(state, section, "Unknown")
      # Should not crash, returns state unchanged
      assert new_state.started_interfaces == state.started_interfaces

      GenServer.stop(pid)
    end

    test "starts a UDPInterface from config", %{configdir: configdir} do
      name = :"test_synth_udp_#{:rand.uniform(100_000)}"

      {:ok, pid} =
        Reticulum.start_link(
          configdir: configdir,
          skip_start: true,
          server_name: name
        )

      state = GenServer.call(name, :get_state)

      section =
        Section.new()
        |> Section.put_scalar("type", "UDPInterface")
        |> Section.put_scalar("enabled", "yes")
        |> Section.put_scalar("listen_ip", "127.0.0.1")
        |> Section.put_scalar("listen_port", "#{49_000 + :rand.uniform(1000)}")
        |> Section.put_scalar("forward_ip", "127.0.0.1")
        |> Section.put_scalar("forward_port", "#{49_000 + :rand.uniform(1000)}")

      new_state = Reticulum.synthesize_interface(state, section, "Test UDP")
      assert length(new_state.started_interfaces) == length(state.started_interfaces) + 1

      # Clean up the started interface
      [iface_pid | _] = new_state.started_interfaces

      if Process.alive?(iface_pid) do
        DynamicSupervisor.terminate_child(RNS.InterfaceSupervisor, iface_pid)
      end

      GenServer.stop(pid)
    end
  end

  # ── Start Local Interface ────────────────────────────────────────────

  describe "start_local_interface" do
    setup do
      tmpdir = System.tmp_dir!()
      configdir = Path.join(tmpdir, "rns_test_local_#{:rand.uniform(100_000)}")
      on_exit(fn -> File.rm_rf!(configdir) end)
      {:ok, configdir: configdir}
    end

    test "standalone mode when share_instance is false", %{configdir: configdir} do
      name = :"test_standalone_#{:rand.uniform(100_000)}"

      File.mkdir_p!(configdir)

      File.write!(Path.join(configdir, "config"), """
      [reticulum]
      share_instance = no

      [logging]
      loglevel = 4
      """)

      {:ok, pid} =
        Reticulum.start_link(
          configdir: configdir,
          skip_start: true,
          server_name: name
        )

      state = GenServer.call(name, :get_state)

      # Manually call start_local_interface
      new_state = Reticulum.start_local_interface(state)

      assert new_state.is_standalone_instance == true
      assert new_state.is_shared_instance == false
      assert new_state.is_connected_to_shared_instance == false

      GenServer.stop(pid)
    end
  end

  # ── Interface Instantiation from Config (full pipeline) ─────────────

  describe "start_configured_interfaces" do
    setup do
      tmpdir = System.tmp_dir!()
      configdir = Path.join(tmpdir, "rns_test_ifaces_#{:rand.uniform(100_000)}")
      on_exit(fn -> File.rm_rf!(configdir) end)
      {:ok, configdir: configdir}
    end

    test "starts interfaces from config sections", %{configdir: configdir} do
      name = :"test_ifaces_#{:rand.uniform(100_000)}"

      port1 = 50_000 + :rand.uniform(1000)
      port2 = 51_000 + :rand.uniform(1000)

      File.mkdir_p!(configdir)

      File.write!(Path.join(configdir, "config"), """
      [reticulum]
      share_instance = no

      [logging]
      loglevel = 4

      [interfaces]
        [[Test UDP 1]]
          type = UDPInterface
          enabled = yes
          listen_ip = 127.0.0.1
          listen_port = #{port1}
          forward_ip = 127.0.0.1
          forward_port = #{port1}

        [[Test UDP 2]]
          type = UDPInterface
          enabled = yes
          listen_ip = 127.0.0.1
          listen_port = #{port2}
          forward_ip = 127.0.0.1
          forward_port = #{port2}
      """)

      {:ok, pid} =
        Reticulum.start_link(
          configdir: configdir,
          skip_start: true,
          server_name: name
        )

      state = GenServer.call(name, :get_state)

      # Mark as standalone so interfaces will be started
      state = %{state | is_standalone_instance: true}
      new_state = Reticulum.start_configured_interfaces(state)

      assert length(new_state.started_interfaces) >= 2

      # Clean up
      for iface_pid <- new_state.started_interfaces do
        if is_pid(iface_pid) and Process.alive?(iface_pid) do
          DynamicSupervisor.terminate_child(RNS.InterfaceSupervisor, iface_pid)
        end
      end

      GenServer.stop(pid)
    end

    test "skips disabled interfaces", %{configdir: configdir} do
      name = :"test_skip_disabled_#{:rand.uniform(100_000)}"

      File.mkdir_p!(configdir)

      File.write!(Path.join(configdir, "config"), """
      [reticulum]
      share_instance = no

      [logging]
      loglevel = 4

      [interfaces]
        [[Disabled UDP]]
          type = UDPInterface
          enabled = no
          listen_ip = 127.0.0.1
          listen_port = 55555
          forward_ip = 127.0.0.1
          forward_port = 55555
      """)

      {:ok, pid} =
        Reticulum.start_link(
          configdir: configdir,
          skip_start: true,
          server_name: name
        )

      state = GenServer.call(name, :get_state)
      state = %{state | is_standalone_instance: true}
      new_state = Reticulum.start_configured_interfaces(state)

      assert new_state.started_interfaces == state.started_interfaces

      GenServer.stop(pid)
    end

    test "returns unchanged state when no interfaces section", %{configdir: configdir} do
      name = :"test_no_ifaces_#{:rand.uniform(100_000)}"

      File.mkdir_p!(configdir)

      File.write!(Path.join(configdir, "config"), """
      [reticulum]
      share_instance = no

      [logging]
      loglevel = 4
      """)

      {:ok, pid} =
        Reticulum.start_link(
          configdir: configdir,
          skip_start: true,
          server_name: name
        )

      state = GenServer.call(name, :get_state)
      state = %{state | is_standalone_instance: true}
      new_state = Reticulum.start_configured_interfaces(state)

      assert new_state.started_interfaces == state.started_interfaces

      GenServer.stop(pid)
    end
  end

  # ── IFAC Key Derivation ──────────────────────────────────────────────

  describe "build_post_init_updates IFAC computation" do
    test "computes IFAC identity when netname is set" do
      params = %{
        outgoing: true,
        interface_mode: 0x00,
        announce_cap: 0.02,
        bootstrap_only: false,
        configured_bitrate: nil,
        ifac_size: nil,
        ifac_netname: "testnet",
        ifac_netkey: nil,
        ingress_control: true,
        ic_max_held_announces: nil,
        ic_burst_hold: nil,
        ic_burst_freq_new: nil,
        ic_burst_freq: nil,
        ic_new_time: nil,
        ic_burst_penalty: nil,
        ic_held_release_interval: nil,
        announce_rate_target: nil,
        announce_rate_grace: nil,
        announce_rate_penalty: nil,
        discoverable: false,
        discovery_params: %{}
      }

      updates = Reticulum.build_post_init_updates(params, %{})
      assert is_binary(updates.ifac_key)
      assert byte_size(updates.ifac_key) == 64
      assert updates.ifac_identity != nil
      assert is_binary(updates.ifac_signature)
    end

    test "computes IFAC identity when both netname and netkey are set" do
      params = %{
        outgoing: true,
        interface_mode: 0x00,
        announce_cap: 0.02,
        bootstrap_only: false,
        configured_bitrate: nil,
        ifac_size: nil,
        ifac_netname: "testnet",
        ifac_netkey: "secret",
        ingress_control: true,
        ic_max_held_announces: nil,
        ic_burst_hold: nil,
        ic_burst_freq_new: nil,
        ic_burst_freq: nil,
        ic_new_time: nil,
        ic_burst_penalty: nil,
        ic_held_release_interval: nil,
        announce_rate_target: nil,
        announce_rate_grace: nil,
        announce_rate_penalty: nil,
        discoverable: false,
        discovery_params: %{}
      }

      updates = Reticulum.build_post_init_updates(params, %{})
      assert is_binary(updates.ifac_key)
      assert byte_size(updates.ifac_key) == 64
    end

    test "skips IFAC computation when neither netname nor netkey is set" do
      params = %{
        outgoing: true,
        interface_mode: 0x00,
        announce_cap: 0.02,
        bootstrap_only: false,
        configured_bitrate: nil,
        ifac_size: nil,
        ifac_netname: nil,
        ifac_netkey: nil,
        ingress_control: true,
        ic_max_held_announces: nil,
        ic_burst_hold: nil,
        ic_burst_freq_new: nil,
        ic_burst_freq: nil,
        ic_new_time: nil,
        ic_burst_penalty: nil,
        ic_held_release_interval: nil,
        announce_rate_target: nil,
        announce_rate_grace: nil,
        announce_rate_penalty: nil,
        discoverable: false,
        discovery_params: %{}
      }

      updates = Reticulum.build_post_init_updates(params, %{})
      refute Map.has_key?(updates, :ifac_key)
      refute Map.has_key?(updates, :ifac_identity)
    end
  end

  # ── Persist Data ─────────────────────────────────────────────────────

  describe "persist and terminate" do
    setup do
      tmpdir = System.tmp_dir!()
      configdir = Path.join(tmpdir, "rns_test_persist_#{:rand.uniform(100_000)}")
      on_exit(fn -> File.rm_rf!(configdir) end)
      {:ok, configdir: configdir}
    end

    test "terminate does not crash", %{configdir: configdir} do
      name = :"test_persist_term_#{:rand.uniform(100_000)}"

      {:ok, pid} =
        Reticulum.start_link(
          configdir: configdir,
          skip_start: true,
          server_name: name
        )

      # Stopping should invoke terminate gracefully
      GenServer.stop(pid)
      refute Process.alive?(pid)
    end
  end

  # ── Add Interface API ───────────────────────────────────────────────

  describe "add_interface" do
    setup do
      tmpdir = System.tmp_dir!()
      configdir = Path.join(tmpdir, "rns_test_add_#{:rand.uniform(100_000)}")
      on_exit(fn -> File.rm_rf!(configdir) end)
      {:ok, configdir: configdir}
    end

    test "rejects when connected to shared instance", %{configdir: configdir} do
      name = :"test_add_reject_#{:rand.uniform(100_000)}"

      {:ok, pid} =
        Reticulum.start_link(
          configdir: configdir,
          skip_start: true,
          server_name: name
        )

      # Manually set state to connected_to_shared_instance
      :sys.replace_state(pid, fn state ->
        %{state | is_connected_to_shared_instance: true}
      end)

      result = GenServer.call(name, {:add_interface, self(), %{}})
      assert result == {:error, :connected_to_shared_instance}

      GenServer.stop(pid)
    end
  end
end
