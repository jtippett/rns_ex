defmodule RNS.Utilities.RNID do
  @moduledoc """
  Reticulum Identity & Encryption Utility.

  Provides identity management, cryptographic operations (sign, verify,
  encrypt, decrypt), and network functions (announce, destination hash display).

  Can be invoked as an escript (`rnid`) or called programmatically via
  `RNS.Utilities.RNID.main/1`.

  ## Usage

      rnid [options]

  ## Options

    * `--config PATH` - Path to alternative Reticulum config directory
    * `-i`, `--identity IDENTITY` - Hexadecimal hash or path to Identity file
    * `-g`, `--generate FILE` - Generate a new Identity and save to file
    * `-m`, `--import DATA` - Import Identity in hex, base32 or base64 format
    * `-x`, `--export` - Export identity to hex, base32 or base64 format
    * `-v`, `--verbose` - Increase verbosity (can be repeated)
    * `-q`, `--quiet` - Decrease verbosity (can be repeated)
    * `-a`, `--announce ASPECTS` - Announce a destination based on this Identity
    * `-H`, `--hash ASPECTS` - Show destination hashes for other aspects
    * `-e`, `--encrypt FILE` - Encrypt file
    * `-d`, `--decrypt FILE` - Decrypt file
    * `-s`, `--sign FILE` - Sign file
    * `-V`, `--validate FILE` - Validate signature
    * `-r`, `--read FILE` - Input file path
    * `-w`, `--write FILE` - Output file path
    * `-f`, `--force` - Write output even if it overwrites existing files
    * `-R`, `--request` - Request unknown Identities from the network
    * `-t SECONDS` - Identity request timeout (default: 15)
    * `-p`, `--print-identity` - Print identity info and exit
    * `-P`, `--print-private` - Allow displaying private keys
    * `-b`, `--base64` - Use base64-encoded input and output
    * `-B`, `--base32` - Use base32-encoded input and output
    * `--version` - Print version and exit
  """

  @app_name "rnid"
  @sig_ext "rsg"
  @encrypt_ext "rfe"
  @chunk_size 16 * 1024 * 1024

  # ── Public accessors for constants ───────────────────────────────────

  @doc "Returns the application name used for rnid destinations."
  @spec app_name() :: String.t()
  def app_name, do: @app_name

  @doc "Returns the signature file extension."
  @spec sig_ext() :: String.t()
  def sig_ext, do: @sig_ext

  @doc "Returns the encrypted file extension."
  @spec encrypt_ext() :: String.t()
  def encrypt_ext, do: @encrypt_ext

  @doc "Returns the chunk size for file I/O operations."
  @spec chunk_size() :: non_neg_integer()
  def chunk_size, do: @chunk_size

  # ── Entry Point ──────────────────────────────────────────────────────

  @doc """
  Entry point for the rnid escript and programmatic invocation.
  """
  @spec main([String.t()]) :: :ok | no_return()
  def main(args) do
    case parse_args(args) do
      {:ok, opts} ->
        if opts.version do
          IO.puts("rnid #{RNS.Version.version()}")
        else
          program_setup(opts)
        end

      {:error, message} ->
        IO.puts(:stderr, "error: #{message}")
        System.halt(1)
    end
  end

  # ── Argument Parsing ─────────────────────────────────────────────────

  @doc """
  Parses command-line arguments into an options map.

  Returns `{:ok, opts}` on success or `{:error, message}` on failure.
  """
  @spec parse_args([String.t()]) :: {:ok, map()} | {:error, String.t()}
  def parse_args(args) do
    {parsed, _rest, invalid} =
      OptionParser.parse(args,
        strict: [
          config: :string,
          identity: :string,
          generate: :string,
          import: :string,
          export: :boolean,
          verbose: :count,
          quiet: :count,
          announce: :string,
          hash: :string,
          encrypt: :string,
          decrypt: :string,
          sign: :string,
          validate: :string,
          read: :string,
          write: :string,
          force: :boolean,
          stdin: :boolean,
          stdout: :boolean,
          request: :boolean,
          timeout: :float,
          print_identity: :boolean,
          print_private: :boolean,
          base64: :boolean,
          base32: :boolean,
          version: :boolean
        ],
        aliases: [
          i: :identity,
          g: :generate,
          m: :import,
          x: :export,
          v: :verbose,
          q: :quiet,
          a: :announce,
          H: :hash,
          e: :encrypt,
          d: :decrypt,
          s: :sign,
          V: :validate,
          r: :read,
          w: :write,
          f: :force,
          I: :stdin,
          O: :stdout,
          R: :request,
          t: :timeout,
          p: :print_identity,
          P: :print_private,
          b: :base64,
          B: :base32
        ]
      )

    if invalid != [] do
      {key, _} = hd(invalid)
      {:error, "unknown option: #{key}"}
    else
      {:ok,
       %{
         configdir: Keyword.get(parsed, :config),
         identity: Keyword.get(parsed, :identity),
         generate: Keyword.get(parsed, :generate),
         import_str: Keyword.get(parsed, :import),
         export: Keyword.get(parsed, :export, false),
         verbosity: Keyword.get(parsed, :verbose, 0),
         quietness: Keyword.get(parsed, :quiet, 0),
         announce: Keyword.get(parsed, :announce),
         hash: Keyword.get(parsed, :hash),
         encrypt: Keyword.get(parsed, :encrypt),
         decrypt: Keyword.get(parsed, :decrypt),
         sign: Keyword.get(parsed, :sign),
         validate: Keyword.get(parsed, :validate),
         read: Keyword.get(parsed, :read),
         write: Keyword.get(parsed, :write),
         force: Keyword.get(parsed, :force, false),
         stdin: Keyword.get(parsed, :stdin, false),
         stdout: Keyword.get(parsed, :stdout, false),
         request: Keyword.get(parsed, :request, false),
         timeout: Keyword.get(parsed, :timeout, RNS.Transport.path_request_timeout() * 1.0),
         print_identity: Keyword.get(parsed, :print_identity, false),
         print_private: Keyword.get(parsed, :print_private, false),
         base64: Keyword.get(parsed, :base64, false),
         base32: Keyword.get(parsed, :base32, false),
         version: Keyword.get(parsed, :version, false)
       }}
    end
  end

  # ── Program Setup ────────────────────────────────────────────────────

  @doc """
  Executes the identity operation specified by the given options.
  """
  @spec program_setup(map()) :: :ok | no_return()
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def program_setup(opts) do
    # Validate: only one crypto operation at a time
    ops =
      [opts.encrypt, opts.decrypt, opts.validate, opts.sign]
      |> Enum.count(&(&1 != nil))

    if ops > 1 do
      RNS.Log.log(
        "This utility currently only supports one of the encrypt, decrypt, sign or verify operations per invocation",
        :error
      )

      System.halt(1)
    end

    # Auto-set read from crypto operation if not specified
    opts = auto_set_read(opts)

    # Handle import first (doesn't need Reticulum)
    if opts.import_str do
      handle_import(opts)
      System.halt(0)
    end

    if opts.generate == nil and opts.identity == nil do
      IO.puts("\nNo identity provided, cannot continue\n")
      print_usage()
      IO.puts("")
      System.halt(2)
    end

    # Start Reticulum
    target_loglevel = 4 + opts.verbosity - opts.quietness

    RNS.Utilities.CLI.start_for_cli(
      logdest: :stdout,
      loglevel: max(target_loglevel, 0),
      configdir: opts.configdir
    )

    # Handle generate
    if opts.generate do
      handle_generate(opts)
    end

    # Load identity
    identity = load_identity(opts)

    if identity == nil do
      System.halt(1)
    end

    # Dispatch to operation
    cond do
      opts.hash -> handle_hash(identity, opts)
      opts.announce -> handle_announce(identity, opts)
      opts.print_identity -> handle_print_identity(identity, opts)
      opts.export -> handle_export(identity, opts)
      opts.validate -> handle_validate_or_crypto(identity, opts)
      opts.sign -> handle_validate_or_crypto(identity, opts)
      opts.encrypt -> handle_validate_or_crypto(identity, opts)
      opts.decrypt -> handle_validate_or_crypto(identity, opts)
      true -> :ok
    end
  end

  # ── Import Handler ──────────────────────────────────────────────────

  @doc """
  Handles importing an identity from hex, base32, or base64 encoded data.
  """
  @spec handle_import(map()) :: :ok | no_return()
  def handle_import(opts) do
    identity_bytes =
      case decode_identity_data(opts.import_str, opts) do
        {:ok, bytes} ->
          bytes

        {:error, msg} ->
          IO.puts("Invalid identity data specified for import: #{msg}")
          System.halt(41)
      end

    identity =
      case safe_from_bytes(identity_bytes) do
        {:ok, id} ->
          id

        {:error, msg} ->
          IO.puts("Could not create Reticulum identity from specified data: #{msg}")
          System.halt(42)
      end

    RNS.Log.log("Identity imported", :info)
    RNS.Log.log("Public Key  : #{format_key(RNS.Identity.public_key(identity), opts)}", :info)

    if identity.prv_bytes do
      if opts.print_private do
        RNS.Log.log(
          "Private Key : #{format_key(RNS.Identity.private_key(identity), opts)}",
          :info
        )
      else
        RNS.Log.log("Private Key : Hidden", :info)
      end
    end

    if opts.write do
      wp = Path.expand(opts.write)

      if File.exists?(wp) and not opts.force do
        IO.puts("File #{wp} already exists, not overwriting")
        System.halt(43)
      else
        case safe_to_file(identity, wp) do
          :ok ->
            RNS.Log.log("Wrote imported identity to #{opts.write}", :info)

          {:error, msg} ->
            IO.puts("Error while writing imported identity to file: #{msg}")
            System.halt(44)
        end
      end
    end
  end

  # ── Generate Handler ────────────────────────────────────────────────

  @doc """
  Handles generating a new identity and saving to file.
  """
  @spec handle_generate(map()) :: no_return()
  def handle_generate(opts) do
    identity = RNS.Identity.new()

    if not opts.force and File.exists?(opts.generate) do
      RNS.Log.log("Identity file #{opts.generate} already exists. Not overwriting.", :error)
      System.halt(3)
    end

    case safe_to_file(identity, opts.generate) do
      :ok ->
        RNS.Log.log("New identity #{inspect(identity)} written to #{opts.generate}", :info)
        System.halt(0)

      {:error, msg} ->
        RNS.Log.log("An error occurred while saving the generated Identity.", :error)
        RNS.Log.log("The contained exception was: #{msg}", :error)
        System.halt(4)
    end
  end

  # ── Identity Loading ────────────────────────────────────────────────

  @doc """
  Loads an identity from a hex hash (via recall) or from a file path.
  """
  @spec load_identity(map()) :: RNS.Identity.t() | nil
  def load_identity(opts) do
    identity_str = opts.identity

    if identity_str == nil do
      nil
    else
      dest_len = div(RNS.Reticulum.truncated_hashlength(), 8) * 2

      if String.length(identity_str) == dest_len and not File.exists?(identity_str) do
        load_identity_from_hash(identity_str, opts)
      else
        load_identity_from_file(identity_str)
      end
    end
  end

  defp load_identity_from_hash(hex_str, opts) do
    case Base.decode16(hex_str, case: :mixed) do
      {:ok, ident_hash} ->
        identity =
          RNS.Identity.recall(ident_hash) ||
            RNS.Identity.recall(ident_hash, from_identity_hash: true)

        cond do
          identity != nil ->
            RNS.Log.log("Recalled Identity #{inspect(identity)}", :info)
            identity

          opts.request ->
            RNS.Transport.request_path(ident_hash)

            found =
              spin(
                fn -> RNS.Identity.recall(ident_hash) != nil end,
                "Requesting unknown Identity for #{RNS.prettyhexrep(ident_hash)}",
                opts.timeout
              )

            if found do
              identity = RNS.Identity.recall(ident_hash)

              RNS.Log.log(
                "Received Identity #{inspect(identity)} for destination #{RNS.prettyhexrep(ident_hash)} from the network",
                :info
              )

              identity
            else
              RNS.Log.log("Identity request timed out", :error)
              System.halt(6)
            end

          true ->
            RNS.Log.log(
              "Could not recall Identity for #{RNS.prettyhexrep(ident_hash)}.",
              :error
            )

            RNS.Log.log(
              "You can query the network for unknown Identities with the -R option.",
              :error
            )

            System.halt(5)
        end

      :error ->
        RNS.Log.log("Invalid hexadecimal hash provided", :error)
        System.halt(7)
    end
  end

  defp load_identity_from_file(path) do
    if not File.exists?(path) do
      RNS.Log.log("Specified Identity file not found", :info)
      System.halt(8)
    end

    case safe_from_file(path) do
      {:ok, identity} ->
        RNS.Log.log("Loaded Identity #{inspect(identity)} from #{path}", :info)
        identity

      {:error, _} ->
        RNS.Log.log("Could not decode Identity from specified file", :info)
        System.halt(9)
    end
  end

  # ── Hash Handler ────────────────────────────────────────────────────

  @doc """
  Shows the destination hash for the given aspects.
  """
  @spec handle_hash(RNS.Identity.t(), map()) :: no_return()
  def handle_hash(identity, opts) do
    aspects = String.split(opts.hash, ".")

    if aspects == [] do
      RNS.Log.log("Invalid destination aspects specified", :error)
      System.halt(32)
    end

    [app_name | aspect_parts] = aspects

    if identity.pub_bytes do
      destination =
        RNS.Destination.new(
          identity,
          RNS.Destination.direction_out(),
          RNS.Destination.single(),
          app_name,
          aspect_parts
        )

      RNS.Log.log(
        "The #{opts.hash} destination for this Identity is #{RNS.prettyhexrep(destination.hash)}",
        :info
      )

      RNS.Log.log("The full destination specifier is #{inspect(destination)}", :info)
      Process.sleep(250)
      System.halt(0)
    else
      RNS.Log.log("An error occurred while attempting to compute the hash.", :error)
      RNS.Log.log("The contained exception was: No public key known", :error)
      System.halt(32)
    end
  end

  # ── Announce Handler ────────────────────────────────────────────────

  @doc """
  Announces a destination based on the given identity.
  """
  @spec handle_announce(RNS.Identity.t(), map()) :: no_return()
  def handle_announce(identity, opts) do
    aspects = String.split(opts.announce, ".")

    if length(aspects) <= 1 do
      RNS.Log.log("Invalid destination aspects specified", :error)
      System.halt(32)
    end

    [app_name | aspect_parts] = aspects

    if identity.prv_bytes do
      destination =
        RNS.Destination.new(
          identity,
          RNS.Destination.direction_in(),
          RNS.Destination.single(),
          app_name,
          aspect_parts
        )

      RNS.Log.log("Created destination #{inspect(destination)}", :info)
      RNS.Log.log("Announcing destination #{RNS.prettyhexrep(destination.hash)}", :info)
      Process.sleep(1100)
      RNS.Destination.announce(destination)
      Process.sleep(250)
      System.halt(0)
    else
      destination =
        RNS.Destination.new(
          identity,
          RNS.Destination.direction_out(),
          RNS.Destination.single(),
          app_name,
          aspect_parts
        )

      RNS.Log.log(
        "The #{opts.announce} destination for this Identity is #{RNS.prettyhexrep(destination.hash)}",
        :info
      )

      RNS.Log.log("The full destination specifier is #{inspect(destination)}", :info)
      RNS.Log.log("Cannot announce this destination, since the private key is not held", :info)
      Process.sleep(250)
      System.halt(33)
    end
  end

  # ── Print Identity Handler ─────────────────────────────────────────

  @doc """
  Prints identity information (public/private keys).
  """
  @spec handle_print_identity(RNS.Identity.t(), map()) :: no_return()
  def handle_print_identity(identity, opts) do
    RNS.Log.log("Public Key  : #{format_key(RNS.Identity.public_key(identity), opts)}", :info)

    if identity.prv_bytes do
      if opts.print_private do
        RNS.Log.log(
          "Private Key : #{format_key(RNS.Identity.private_key(identity), opts)}",
          :info
        )
      else
        RNS.Log.log("Private Key : Hidden", :info)
      end
    end

    System.halt(0)
  end

  # ── Export Handler ──────────────────────────────────────────────────

  @doc """
  Exports the identity's private key in the specified encoding.
  """
  @spec handle_export(RNS.Identity.t(), map()) :: no_return()
  def handle_export(identity, opts) do
    if identity.prv_bytes do
      RNS.Log.log(
        "Exported Identity : #{format_key(RNS.Identity.private_key(identity), opts)}",
        :info
      )
    else
      RNS.Log.log("Identity doesn't hold a private key, cannot export", :info)
      System.halt(50)
    end

    System.halt(0)
  end

  # ── Validate / Sign / Encrypt / Decrypt ─────────────────────────────

  @doc """
  Handles file-based cryptographic operations: validate, sign, encrypt, decrypt.
  """
  @spec handle_validate_or_crypto(RNS.Identity.t(), map()) :: :ok | no_return()
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def handle_validate_or_crypto(identity, opts) do
    # Auto-derive signature read file if validate and no read specified
    opts =
      if opts.validate and opts.read == nil and
           String.ends_with?(String.downcase(opts.validate), ".#{@sig_ext}") do
        %{opts | read: String.replace(opts.validate, ".#{@sig_ext}", "")}
      else
        opts
      end

    # Validate file existence for validate operation
    if opts.validate do
      if not File.exists?(opts.validate) do
        RNS.Log.log("Signature file #{opts.validate} not found", :error)
        System.halt(10)
      end

      if opts.read and not File.exists?(opts.read) do
        RNS.Log.log("Input file #{opts.read} not found", :error)
        System.halt(11)
      end
    end

    # Read input file
    data_input =
      if opts.read do
        if not File.exists?(opts.read) do
          RNS.Log.log("Input file #{opts.read} not found", :error)
          System.halt(12)
        end

        opts.read
      end

    # Auto-set write paths
    opts = auto_set_write(opts)

    # Check sign permissions
    if opts.sign and identity.prv_bytes == nil do
      RNS.Log.log("Specified Identity does not hold a private key. Cannot sign.", :error)
      System.halt(14)
    end

    # Auto-set sign output
    opts =
      if opts.sign and opts.write == nil and not opts.stdout and opts.read do
        %{opts | write: "#{opts.read}.#{@sig_ext}"}
      else
        opts
      end

    # Check for overwrite
    if opts.write do
      if not opts.force and File.exists?(opts.write) do
        RNS.Log.log("Output file #{opts.write} already exists. Not overwriting.", :error)
        System.halt(15)
      end
    end

    cond do
      opts.sign -> do_sign(identity, data_input, opts)
      opts.validate -> do_validate(identity, data_input, opts)
      opts.encrypt -> do_encrypt(identity, data_input, opts)
      opts.decrypt -> do_decrypt(identity, data_input, opts)
      true -> :ok
    end
  end

  # ── Sign Operation ──────────────────────────────────────────────────

  defp do_sign(identity, data_input, opts) do
    if identity.prv_bytes == nil do
      RNS.Log.log("Specified Identity does not hold a private key. Cannot sign.", :error)
      System.halt(16)
    end

    if data_input == nil do
      if not opts.stdout do
        RNS.Log.log("Signing requested, but no input data specified", :error)
      end

      System.halt(17)
    end

    if opts.write == nil do
      if not opts.stdout do
        RNS.Log.log("Signing requested, but no output specified", :error)
      end

      System.halt(18)
    end

    if not opts.stdout do
      RNS.Log.log("Signing #{opts.read}", :info)
    end

    try do
      data = File.read!(data_input)
      signature = RNS.Identity.sign(identity, data)
      File.write!(opts.write, signature)

      if not opts.stdout and opts.read do
        RNS.Log.log(
          "File #{opts.read} signed with #{inspect(identity)} to #{opts.write}",
          :info
        )
      end

      System.halt(0)
    rescue
      e ->
        if not opts.stdout do
          RNS.Log.log("An error occurred while signing data.", :error)
          RNS.Log.log("The contained exception was: #{Exception.message(e)}", :error)
        end

        System.halt(19)
    end
  end

  # ── Validate Operation ──────────────────────────────────────────────

  defp do_validate(identity, data_input, opts) do
    if data_input == nil do
      if not opts.stdout do
        RNS.Log.log("Signature verification requested, but no input data specified", :error)
      end

      System.halt(20)
    end

    try do
      sig_data = File.read!(opts.validate)
      file_data = File.read!(data_input)

      validated = RNS.Identity.validate(identity, sig_data, file_data)

      if validated do
        if not opts.stdout do
          RNS.Log.log(
            "Signature #{opts.validate} for file #{opts.read} made by Identity #{inspect(identity)} is valid",
            :info
          )
        end

        System.halt(0)
      else
        if not opts.stdout do
          RNS.Log.log(
            "Signature #{opts.validate} for file #{opts.read} is invalid",
            :error
          )
        end

        System.halt(22)
      end
    rescue
      e ->
        if not opts.stdout do
          RNS.Log.log("An error occurred while validating signature.", :error)
          RNS.Log.log("The contained exception was: #{Exception.message(e)}", :error)
        end

        System.halt(23)
    end
  end

  # ── Encrypt Operation ───────────────────────────────────────────────

  defp do_encrypt(identity, data_input, opts) do
    if data_input == nil do
      if not opts.stdout do
        RNS.Log.log("Encryption requested, but no input data specified", :error)
      end

      System.halt(24)
    end

    if opts.write == nil do
      if not opts.stdout do
        RNS.Log.log("Encryption requested, but no output specified", :error)
      end

      System.halt(25)
    end

    if not opts.stdout do
      RNS.Log.log("Encrypting #{opts.read}", :info)
    end

    try do
      encrypt_file_chunked(identity, data_input, opts.write)

      if not opts.stdout and opts.read do
        RNS.Log.log(
          "File #{opts.read} encrypted for #{inspect(identity)} to #{opts.write}",
          :info
        )
      end

      System.halt(0)
    rescue
      e ->
        if not opts.stdout do
          RNS.Log.log("An error occurred while encrypting data.", :error)
          RNS.Log.log("The contained exception was: #{Exception.message(e)}", :error)
        end

        System.halt(26)
    end
  end

  # ── Decrypt Operation ───────────────────────────────────────────────

  defp do_decrypt(identity, data_input, opts) do
    if identity.prv_bytes == nil do
      RNS.Log.log("Specified Identity does not hold a private key. Cannot decrypt.", :error)
      System.halt(27)
    end

    if data_input == nil do
      if not opts.stdout do
        RNS.Log.log("Decryption requested, but no input data specified", :error)
      end

      System.halt(28)
    end

    if opts.write == nil do
      if not opts.stdout do
        RNS.Log.log("Decryption requested, but no output specified", :error)
      end

      System.halt(29)
    end

    if not opts.stdout do
      RNS.Log.log("Decrypting #{opts.read}...", :info)
    end

    try do
      decrypt_file_chunked(identity, data_input, opts.write, opts)

      if not opts.stdout and opts.read do
        RNS.Log.log(
          "File #{opts.read} decrypted with #{inspect(identity)} to #{opts.write}",
          :info
        )
      end

      System.halt(0)
    rescue
      e ->
        if not opts.stdout do
          RNS.Log.log("An error occurred while decrypting data.", :error)
          RNS.Log.log("The contained exception was: #{Exception.message(e)}", :error)
        end

        System.halt(31)
    end
  end

  # ── Key Formatting ─────────────────────────────────────────────────

  @doc """
  Formats a binary key as hex, base32, or base64 based on options.
  """
  @spec format_key(binary(), map()) :: String.t()
  def format_key(key_bytes, opts) do
    cond do
      opts.base64 -> Base.url_encode64(key_bytes)
      opts.base32 -> Base.encode32(key_bytes)
      true -> RNS.hexrep(key_bytes, false)
    end
  end

  # ── Data Decoding ──────────────────────────────────────────────────

  @doc """
  Decodes identity data from hex, base32, or base64 format based on options.

  Returns `{:ok, bytes}` or `{:error, reason}`.
  """
  @spec decode_identity_data(String.t(), map()) :: {:ok, binary()} | {:error, String.t()}
  def decode_identity_data(data_str, opts) do
    cond do
      opts.base64 ->
        case Base.url_decode64(data_str) do
          {:ok, bytes} -> {:ok, bytes}
          :error -> {:error, "Invalid base64 data"}
        end

      opts.base32 ->
        case Base.decode32(data_str) do
          {:ok, bytes} -> {:ok, bytes}
          :error -> {:error, "Invalid base32 data"}
        end

      true ->
        case Base.decode16(data_str, case: :mixed) do
          {:ok, bytes} -> {:ok, bytes}
          :error -> {:error, "Invalid hexadecimal data"}
        end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ── Spinner ────────────────────────────────────────────────────────

  @doc """
  Displays a spinner while waiting for a condition to become true.

  Returns `true` if the condition was met, `false` if timeout expired.
  """
  @spec spin((-> boolean()), String.t(), number()) :: boolean()
  def spin(until_fn, msg, timeout) do
    timeout_at = System.system_time(:millisecond) + trunc(timeout * 1000)
    IO.write("#{msg}  ")
    result = do_spin(until_fn, timeout_at, 0)
    IO.write("\r#{String.duplicate(" ", String.length(msg) + 2)}\r")
    result
  end

  defp do_spin(until_fn, timeout_at, i) do
    syms = String.graphemes("⢄⢂⢁⡁⡈⡐⡠")

    cond do
      until_fn.() ->
        true

      System.system_time(:millisecond) >= timeout_at ->
        false

      true ->
        Process.sleep(100)
        sym = Enum.at(syms, rem(i, length(syms)))
        IO.write("\b\b#{sym} ")
        do_spin(until_fn, timeout_at, i + 1)
    end
  end

  # ── File I/O Helpers ───────────────────────────────────────────────

  defp encrypt_file_chunked(identity, input_path, output_path) do
    input_data = File.read!(input_path)

    chunks =
      input_data
      |> chunk_binary(@chunk_size)
      |> Enum.map(fn chunk -> RNS.Identity.encrypt(identity, chunk) end)

    File.write!(output_path, Enum.join(chunks))
  end

  defp decrypt_file_chunked(identity, input_path, output_path, opts) do
    input_data = File.read!(input_path)

    chunks =
      input_data
      |> chunk_binary(@chunk_size)
      |> Enum.map(fn chunk ->
        case RNS.Identity.decrypt(identity, chunk) do
          nil ->
            if not opts.stdout do
              RNS.Log.log("Data could not be decrypted with the specified Identity", :info)
            end

            System.halt(30)

          plaintext ->
            plaintext
        end
      end)

    File.write!(output_path, Enum.join(chunks))
  end

  @doc """
  Splits a binary into chunks of the given size.
  """
  @spec chunk_binary(binary(), pos_integer()) :: [binary()]
  def chunk_binary(<<>>, _size), do: []

  def chunk_binary(data, size) when byte_size(data) <= size do
    [data]
  end

  def chunk_binary(data, size) do
    <<chunk::binary-size(size), rest::binary>> = data
    [chunk | chunk_binary(rest, size)]
  end

  # ── Private Helpers ────────────────────────────────────────────────

  defp auto_set_read(opts) do
    if opts.read == nil do
      cond do
        opts.encrypt -> %{opts | read: opts.encrypt}
        opts.decrypt -> %{opts | read: opts.decrypt}
        opts.sign -> %{opts | read: opts.sign}
        true -> opts
      end
    else
      opts
    end
  end

  defp auto_set_write(opts) do
    opts =
      if opts.encrypt and opts.write == nil and not opts.stdout and opts.read do
        %{opts | write: "#{opts.read}.#{@encrypt_ext}"}
      else
        opts
      end

    if opts.decrypt and opts.write == nil and not opts.stdout and opts.read and
         String.ends_with?(String.downcase(opts.read), ".#{@encrypt_ext}") do
      %{opts | write: String.replace(opts.read, ".#{@encrypt_ext}", "")}
    else
      opts
    end
  end

  defp safe_from_bytes(bytes) do
    case RNS.Identity.from_bytes(bytes) do
      nil -> {:error, "Could not parse identity data"}
      identity -> {:ok, identity}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp safe_from_file(path) do
    case RNS.Identity.from_file(path) do
      nil -> {:error, "Could not decode identity from file"}
      identity -> {:ok, identity}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp safe_to_file(identity, path) do
    RNS.Identity.to_file(identity, path)
    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp print_usage do
    IO.puts("""
    Reticulum Identity & Encryption Utility

    Usage: rnid [options]

    Options:
      --config PATH           Path to alternative Reticulum config directory
      -i, --identity ID       Hexadecimal hash or path to Identity file
      -g, --generate FILE     Generate a new Identity and save to file
      -m, --import DATA       Import Identity in hex, base32 or base64 format
      -x, --export            Export identity to hex, base32 or base64 format
      -v, --verbose           Increase verbosity (can be repeated)
      -q, --quiet             Decrease verbosity (can be repeated)
      -a, --announce ASPECTS  Announce a destination based on this Identity
      -H, --hash ASPECTS      Show destination hashes for other aspects
      -e, --encrypt FILE      Encrypt file
      -d, --decrypt FILE      Decrypt file
      -s, --sign FILE         Sign file
      -V, --validate FILE     Validate signature
      -r, --read FILE         Input file path
      -w, --write FILE        Output file path
      -f, --force             Write output even if it overwrites existing files
      -R, --request           Request unknown Identities from the network
      -t SECONDS              Identity request timeout (default: 15)
      -p, --print-identity    Print identity info and exit
      -P, --print-private     Allow displaying private keys
      -b, --base64            Use base64-encoded input and output
      -B, --base32            Use base32-encoded input and output
      --version               Print version and exit
    """)
  end
end
