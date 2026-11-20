defmodule Mix.Tasks.Npm.Publish do
  @shortdoc "Publish package to the npm registry"

  @moduledoc """
  Publish the current package and its tarball to the configured npm registry.

      mix npm.publish
      mix npm.publish --dry-run --tag beta
      mix npm.publish --access public

  Uses the same file selection as `mix npm.pack`. `publishConfig` can set the
  registry, tag and access; command-line tag/access override those defaults.
  Scoped registries use their own matching token, and uploads never follow
  redirects. A dry run lists the packed files without contacting the registry.

  Lifecycle scripts are not executed automatically. Run any required build or
  preparation scripts explicitly before publishing. Bundled dependencies are
  currently rejected by the packer.
  """

  use Mix.Task

  alias NPM.Package.PublishConfig
  alias NPM.Security.RegistryPolicy

  @impl true
  def run(args) do
    NPM.MixBootstrap.ensure_started!()

    {opts, positional, invalid} =
      OptionParser.parse(args, strict: [tag: :string, access: :string, dry_run: :boolean])

    if positional != [] or invalid != [], do: Mix.raise("Invalid npm.publish options")

    with {:ok, data} <- NPM.JSON.read_file("package.json"),
         :ok <- validate_publish(data),
         {:ok, settings} <- publish_settings(data, opts),
         {:ok, artifact} <- NPM.Pack.tarball(".") do
      if Keyword.get(opts, :dry_run, false) do
        print_dry_run(artifact, settings)
      else
        publish(artifact, settings)
      end
    else
      {:error, reason} -> Mix.raise("Publish failed: #{inspect(reason)}")
    end
  end

  defp validate_publish(%{"private" => true}), do: {:error, :private_package}

  defp validate_publish(%{"name" => name, "version" => version})
       when is_binary(name) and is_binary(version) do
    cond do
      not NPM.Scope.installable_name?(name) or name != String.downcase(name) ->
        {:error, :invalid_package_name}

      not match?({:ok, _}, Version.parse(version)) ->
        {:error, :invalid_package_version}

      true ->
        :ok
    end
  end

  defp validate_publish(_data), do: {:error, :missing_package_name_or_version}

  defp publish_settings(data, opts) do
    tag = Keyword.get(opts, :tag, PublishConfig.tag(data))
    access = Keyword.get(opts, :access, PublishConfig.access(data))
    registry = PublishConfig.registry(data) || NPM.Config.registry_for(data["name"])

    cond do
      not is_binary(tag) or not Regex.match?(~r/^[A-Za-z][A-Za-z0-9._-]*\z/, tag) ->
        {:error, :invalid_dist_tag}

      access not in ["public", "restricted"] ->
        {:error, :invalid_access}

      not is_binary(registry) ->
        {:error, :invalid_publish_registry}

      true ->
        uri = URI.parse(registry)

        if uri.scheme in ["http", "https"] and is_binary(uri.host) and
             is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) do
          {:ok, %{tag: tag, access: access, registry: String.trim_trailing(registry, "/")}}
        else
          {:error, :invalid_publish_registry}
        end
    end
  end

  defp print_dry_run(artifact, settings) do
    Mix.shell().info("Dry run — would publish:")
    Mix.shell().info("  package: #{artifact.data["name"]}")
    Mix.shell().info("  version: #{artifact.data["version"]}")
    Mix.shell().info("  tag:     #{settings.tag}")
    Mix.shell().info("  access:  #{settings.access}")
    Enum.each(artifact.files, &Mix.shell().info("  #{&1}"))
    :ok
  end

  defp publish(artifact, settings) do
    name = artifact.data["name"]
    version = artifact.data["version"]
    registry = settings.registry
    RegistryPolicy.validate_url!(registry)
    token = NPM.Config.auth_token(registry)

    if is_nil(token) or token == "", do: Mix.raise("Publish failed: no auth token for registry")

    url = "#{registry}/#{NPM.Registry.encode_package(name)}"

    case NPM.HTTPClient.put(url,
           json: publish_body(artifact, settings),
           headers: [authorization: "Bearer #{token}"],
           redirect: false
         ) do
      {:ok, %{status: status}} when status in [200, 201] ->
        Mix.shell().info("Published #{name}@#{version}")
        :ok

      {:ok, %{status: status}} ->
        Mix.raise("Publish failed: HTTP #{status}")

      {:error, reason} ->
        Mix.raise("Publish failed: #{inspect(reason)}")
    end
  end

  defp publish_body(artifact, settings) do
    data = artifact.data
    name = data["name"]
    version = data["version"]
    attachment_name = "#{NPM.Scope.bare_name(name)}-#{version}.tgz"
    tarball_url = "#{settings.registry}/#{name}/-/#{attachment_name}"

    dist = %{
      "tarball" => tarball_url,
      "shasum" => Base.encode16(:crypto.hash(:sha, artifact.tarball), case: :lower),
      "integrity" => "sha512-" <> Base.encode64(:crypto.hash(:sha512, artifact.tarball))
    }

    manifest = data |> Map.put("_id", "#{name}@#{version}") |> Map.put("dist", dist)

    %{
      "_id" => name,
      "name" => name,
      "description" => Map.get(data, "description", ""),
      "dist-tags" => %{settings.tag => version},
      "access" => settings.access,
      "versions" => %{version => manifest},
      "_attachments" => %{
        attachment_name => %{
          "content_type" => "application/octet-stream",
          "data" => Base.encode64(artifact.tarball),
          "length" => byte_size(artifact.tarball)
        }
      }
    }
  end
end
