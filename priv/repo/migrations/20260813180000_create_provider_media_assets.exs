defmodule Glific.Repo.Migrations.CreateProviderMediaAssets do
  use Ecto.Migration

  @moduledoc """
  ADR-017 (docs/adrs/ADR-017-swiftchat-media-asset-registry.md): a new
  org-scoped provider-media-asset registry, keyed by
  `(organization_id, provider, source_url, content_sha256)`. Provider-internal
  infrastructure only — never a column on `messages_media`, never exposed via
  GraphQL (ADR-006's URL-above-the-provider boundary). Additive.
  """

  def change do
    create table(:provider_media_assets) do
      add :provider, :string,
        null: false,
        comment: "BSP shortcode this mapping was uploaded to, e.g. \"swiftchat\""

      add :source_url, :text,
        null: false,
        comment:
          "The public URL Glific already stores for the media (MessageMedia.source_url / session_templates media / interactive_content header)"

      add :content_sha256, :string,
        null: false,
        comment:
          "Hex-encoded SHA-256 of the fetched bytes at upload time — the content-identity key (ADR-017: a stable URL whose bytes change would otherwise poison the cache)"

      add :provider_media_id, :string,
        null: false,
        comment: "The provider's returned media id for this exact content identity"

      add :content_type, :string,
        comment:
          "MIME type sent to the provider on upload, kept for informational/debugging purposes"

      add :organization_id, references(:organizations, on_delete: :delete_all),
        null: false,
        comment: "Organization scope"

      timestamps(type: :utc_datetime)
    end

    create unique_index(
             :provider_media_assets,
             [:organization_id, :provider, :source_url, :content_sha256],
             name: :provider_media_assets_org_provider_url_hash_index
           )

    create index(:provider_media_assets, [:organization_id])
  end
end
