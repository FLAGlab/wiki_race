import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/wiki_race_platform start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :wiki_race_platform, WikiRacePlatformWeb.Endpoint, server: true
end

config :wiki_race_platform, WikiRacePlatformWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# The Kiwix instance is a different host in every environment: localhost in
# development, the Wikipedia VM in production.
config :wiki_race_platform, :kiwix,
  base_url: System.get_env("KIWIX_BASE_URL", "http://localhost:8080"),
  book: System.get_env("KIWIX_BOOK", "wikipedia_en_all_nopic")

# The harness claims a `:global` name, so exactly one node in the cluster may
# run it. Player nodes start the same app with START_HARNESS=false. A
# split-off harness node (kept off the same node as the web app and its
# secrets) sets START_WEB=false instead. The default, single-node setup
# runs both and needs neither var.
if config_env() != :test do
  config :wiki_race_platform,
         :start_harness,
         System.get_env("START_HARNESS", "true") == "true"

  config :wiki_race_platform,
         :start_web,
         System.get_env("START_WEB", "true") == "true"

  # Where `Tournament.Store` (results persistence) and `Deploy.Server`
  # actually run: the web node, whether that's this node or a different
  # one. Defaults to `node()` so a single combined node addresses itself.
  web_node =
    case System.get_env("WEB_NODE") do
      nil -> node()
      name -> String.to_atom(name)
    end

  config :wiki_race_platform, :web_node, web_node

  # Where `Race.Dispatcher`/`Race.Instance` actually run: the only node
  # that should ever open a distribution link to a player. Same
  # self-addressing default as web_node above.
  harness_node =
    case System.get_env("HARNESS_NODE") do
      nil -> node()
      name -> String.to_atom(name)
    end

  config :wiki_race_platform, :harness_node, harness_node
end

# Where finished race results are appended. Overridable so a deployment can
# point it at a mounted volume; the test env sets its own path at compile
# time and is never touched here.
if config_env() != :test do
  config :wiki_race_platform, :tournament_store,
    data_dir: System.get_env("WIKI_RACE_DATA_DIR", "priv/data")
end

# The university VMs, started by `deploy/final/wikirace` (see DEPLOY.md).
# The roster is every group of `deploy/final/groups.txt`, raced in the
# tournament of config.exs. Every group's release is unpacked on both player
# VMs, and each match starts its crawlers there (WikiRacePlatform.Deploy.Match).
# The VMs have no Docker. All four run the same Ubuntu, so the platform VM
# builds the releases with its own Erlang and Elixir.
if config_env() == :dev and System.get_env("WIKI_RACE_VMS") == "true" do
  config :wiki_race_platform, :tournament,
    roster: Enum.map(WikiRacePlatform.Deploy.GroupsFile.read!(), & &1.name)

  config :wiki_race_platform, :deploy,
    builder: :native,
    player_hosts: [System.fetch_env!("PLAYER1_IP"), System.fetch_env!("PLAYER2_IP")]
end

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :wiki_race_platform, WikiRacePlatformWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/wiki_race_platform_web/router\.ex$"E,
        ~r"lib/wiki_race_platform_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :wiki_race_platform, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :wiki_race_platform, WikiRacePlatformWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :wiki_race_platform, WikiRacePlatformWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :wiki_race_platform, WikiRacePlatformWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :wiki_race_platform, WikiRacePlatform.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://swoosh.hexdocs.pm/Swoosh.html#module-installation for details.
end
