defmodule RNS.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/jamesagada/rns_ex"

  def project do
    [
      app: :rns_ex,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      consolidate_protocols: Mix.env() != :test,
      deps: deps(),
      package: package(),
      dialyzer: [
        plt_add_apps: [:crypto],
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"}
      ],
      name: "RNS",
      description: description(),
      source_url: @source_url,
      homepage_url: @source_url,
      docs: docs(),
      escript: escript()
    ]
  end

  defp description do
    """
    Elixir port of the Reticulum Network Stack — encrypted, self-configuring
    mesh networking with zero infrastructure requirements. Provides Identity,
    Destination, Link, Channel, Buffer, and Resource abstractions over
    multiple interface types (UDP, TCP, LoRa, I2P, serial, and more).
    """
  end

  defp package do
    [
      name: "rns_ex",
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url
      },
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      source_ref: "v#{@version}",
      source_url: @source_url,
      groups_for_modules: [
        "Core Protocol": [
          RNS,
          RNS.Identity,
          RNS.Destination,
          RNS.Packet,
          RNS.PacketReceipt,
          RNS.Link,
          RNS.Transport
        ],
        Communication: [
          RNS.Channel,
          RNS.Buffer,
          RNS.Resource
        ],
        Cryptography: [
          RNS.Cryptography,
          RNS.Cryptography.Hashes,
          RNS.Cryptography.HMAC,
          RNS.Cryptography.HKDF,
          RNS.Cryptography.PKCS7,
          RNS.Cryptography.AES,
          RNS.Cryptography.X25519,
          RNS.Cryptography.Ed25519,
          RNS.Cryptography.Token
        ],
        Interfaces: [
          RNS.Interfaces.Interface
        ],
        System: [
          RNS.Reticulum,
          RNS.Application,
          RNS.Log,
          RNS.Discovery,
          RNS.Resolver
        ],
        Utilities: [
          RNS.Utilities.RNSD,
          RNS.Utilities.RNStatus,
          RNS.Utilities.RNPath,
          RNS.Utilities.RNProbe,
          RNS.Utilities.RNID,
          RNS.Utilities.RNCP,
          RNS.Utilities.RNX,
          RNS.Utilities.RNIR,
          RNS.Utilities.RNPKG
        ]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {RNS.Application, []}
    ]
  end

  defp escript do
    [
      main_module: RNS.Utilities.RNSD,
      name: "rnsd"
    ]
  end

  defp deps do
    [
      {:eddy, "~> 1.0"},
      {:msgpax, "~> 2.4"},
      # Dev/test only
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.0", only: :test},
      {:jason, "~> 1.4"},
      {:benchee, "~> 1.3", only: :dev}
    ]
  end
end
