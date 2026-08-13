defmodule Glific.Providers.MediaAssets.ProviderMediaAsset do
  @moduledoc """
  Org-scoped registry mapping a BSP provider's uploaded-media id back to the
  content identity that produced it (`docs/adrs/ADR-017-swiftchat-media-asset-registry.md`).

  This is provider-internal infrastructure, on the same footing as an access
  token (ADR-006/ADR-017): it has no GraphQL surface and is never read by
  anything above a provider module (`Glific.Providers.Swiftchat.*`).
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Glific.Partners.Organization
  alias Glific.Providers.MediaAssets.ProviderMediaAsset

  @required_fields [
    :organization_id,
    :provider,
    :source_url,
    :content_sha256,
    :provider_media_id
  ]
  @optional_fields [:content_type]

  # Hex-encoded SHA-256 is always exactly 64 lowercase hex characters.
  @content_sha256_pattern ~r/\A[a-f0-9]{64}\z/

  @type t() :: %__MODULE__{
          __meta__: Ecto.Schema.Metadata.t(),
          id: non_neg_integer | nil,
          provider: String.t() | nil,
          source_url: String.t() | nil,
          content_sha256: String.t() | nil,
          provider_media_id: String.t() | nil,
          content_type: String.t() | nil,
          organization_id: non_neg_integer | nil,
          organization: Organization.t() | Ecto.Association.NotLoaded.t() | nil,
          inserted_at: :utc_datetime | nil,
          updated_at: :utc_datetime | nil
        }

  schema "provider_media_assets" do
    field :provider, :string
    field :source_url, :string
    field :content_sha256, :string
    field :provider_media_id, :string
    field :content_type, :string

    belongs_to :organization, Organization

    timestamps(type: :utc_datetime)
  end

  @doc """
  Standard changeset pattern we use for all data types.
  """
  @spec changeset(ProviderMediaAsset.t(), map()) :: Ecto.Changeset.t()
  def changeset(provider_media_asset, attrs) do
    provider_media_asset
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_format(:content_sha256, @content_sha256_pattern,
      message: "must be a 64-character hex-encoded SHA-256"
    )
    |> foreign_key_constraint(:organization_id)
    |> unique_constraint([:organization_id, :provider, :source_url, :content_sha256],
      name: :provider_media_assets_org_provider_url_hash_index
    )
  end
end
