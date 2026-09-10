defmodule NornsSdk.MixProject do
  use Mix.Project

  def project do
    [
      app: :norns_sdk,
      version: "0.3.0",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Elixir SDK for Norns — durable agent runtime on BEAM",
      package: package(),
      source_url: "https://github.com/nornscode/norns-sdk-elixir",
      docs: [main: "readme", extras: ["README.md", "CHANGELOG.md"]]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:req_llm, "~> 1.9"},
      {:slipstream, "~> 1.0"},
      {:jason, "~> 1.4"},

      # Dev / CI
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      maintainers: ["Anson MacKeracher"],
      files: ~w(lib mix.exs README.md LICENSE CHANGELOG.md),
      links: %{
        "GitHub" => "https://github.com/nornscode/norns-sdk-elixir",
        "Norns Runtime" => "https://github.com/nornscode/norns"
      }
    ]
  end
end
