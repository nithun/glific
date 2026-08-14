defmodule Glific.Providers.MediaAssets do
  @moduledoc """
  Context API for the org-scoped provider-media-asset registry
  (`docs/adrs/ADR-017-swiftchat-media-asset-registry.md`).

  This is Seam B shaped (`docs/architecture.md` §9) but deliberately has no
  GraphQL surface — it is provider-internal infrastructure. Every lookup here
  rides `Glific.Repo.prepare_query/3`'s automatic `organization_id` scoping;
  nothing in this module ever passes `skip_organization_id: true` (L-002).

  Only `Glific.Providers.Swiftchat.*` (and, later, other provider modules)
  should call this context — a media-id cache is provider-internal state on
  the same footing as an access token (ADR-006/ADR-017).
  """

  alias Glific.{
    Providers.MediaAssets.ProviderMediaAsset,
    Repo
  }

  @doc """
  Returns the list of provider media assets, using the standard
  `%{filter: ..., opts: ...}` shape.
  """
  @spec list_provider_media_assets(map()) :: [ProviderMediaAsset.t()]
  def list_provider_media_assets(args),
    do: Repo.list_filter(args, ProviderMediaAsset, &Repo.opts_with_id/2, &Repo.filter_with/2)

  @doc """
  Returns the count of provider media assets, using the same filter as
  `list_provider_media_assets/1`.
  """
  @spec count_provider_media_assets(map()) :: integer()
  def count_provider_media_assets(args),
    do: Repo.count_filter(args, ProviderMediaAsset, &Repo.filter_with/2)

  @doc """
  Gets a single provider media asset.

  Raises `Ecto.NoResultsError` if the asset does not exist.
  """
  @spec get_provider_media_asset!(non_neg_integer()) :: ProviderMediaAsset.t()
  def get_provider_media_asset!(id), do: Repo.get!(ProviderMediaAsset, id)

  @doc """
  Fetches a single provider media asset by id, returning an `:ok`/`:error`
  tuple instead of raising.
  """
  @spec fetch_provider_media_asset(non_neg_integer()) ::
          {:ok, ProviderMediaAsset.t()} | {:error, [String.t()]}
  def fetch_provider_media_asset(id), do: Repo.fetch(ProviderMediaAsset, id)

  @doc """
  Creates a provider media asset.
  """
  @spec create_provider_media_asset(map()) ::
          {:ok, ProviderMediaAsset.t()} | {:error, Ecto.Changeset.t()}
  def create_provider_media_asset(attrs) do
    %ProviderMediaAsset{}
    |> ProviderMediaAsset.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a provider media asset.
  """
  @spec update_provider_media_asset(ProviderMediaAsset.t(), map()) ::
          {:ok, ProviderMediaAsset.t()} | {:error, Ecto.Changeset.t()}
  def update_provider_media_asset(%ProviderMediaAsset{} = provider_media_asset, attrs) do
    provider_media_asset
    |> ProviderMediaAsset.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a provider media asset.
  """
  @spec delete_provider_media_asset(ProviderMediaAsset.t()) ::
          {:ok, ProviderMediaAsset.t()} | {:error, Ecto.Changeset.t()}
  def delete_provider_media_asset(%ProviderMediaAsset{} = provider_media_asset),
    do: Repo.delete(provider_media_asset)

  @doc """
  Registry lookup keyed on the full content identity ADR-017 settled on:
  `(organization_id, provider, source_url, content_sha256)`. `organization_id`
  is never taken as an argument here — it comes from `Repo.prepare_query/3`'s
  process-dictionary scoping, same as every other context read in Glific, so
  a caller cannot accidentally look up (or leak) another org's mapping.
  """
  @spec fetch_by_content(String.t(), String.t(), String.t()) ::
          {:ok, ProviderMediaAsset.t()} | {:error, [String.t()]}
  def fetch_by_content(provider, source_url, content_sha256) do
    Repo.fetch_by(ProviderMediaAsset, %{
      provider: provider,
      source_url: source_url,
      content_sha256: content_sha256
    })
  end

  @doc """
  Upload-on-miss/cache-on-success (ADR-017): stores the
  `(organization_id, provider, source_url, content_sha256) -> provider_media_id`
  mapping. If a mapping already exists for this exact content identity (the
  self-healing re-upload path), the existing row's `provider_media_id`
  (and `content_type`) are updated in place rather than inserting a
  duplicate.

  Conflict-safe against the concurrent-resolver race: two processes can both
  read a cache miss from `fetch_by_content/3` before either has inserted
  (upload-on-miss is not itself locked), so the `INSERT` here can lose to a
  sibling process's `INSERT` on the composite
  `provider_media_assets_org_provider_url_hash_index` unique constraint. When
  that happens we do NOT surface the insert error to the caller — we
  re-fetch and return the winning row, exactly as if we'd hit the cache in
  the first place.

  Semantic decision: the LOSER's freshly-uploaded `provider_media_id` (the
  attrs this call was about to insert) is discarded in favor of the
  winner's already-committed id. The orphaned upload on the BSP side is
  accepted as-is — SwiftChat delete is soft/best-effort per the ADR-017
  audit, so there is no reliable cleanup call to make here anyway, and the
  bounded quota risk of a stray upload is tracked by the D5 ask.
  """
  @spec put_asset(map()) :: {:ok, ProviderMediaAsset.t()} | {:error, Ecto.Changeset.t()}
  def put_asset(
        %{provider: provider, source_url: source_url, content_sha256: content_sha256} = attrs
      ) do
    case fetch_by_content(provider, source_url, content_sha256) do
      {:ok, existing} ->
        update_provider_media_asset(
          existing,
          Map.take(attrs, [:provider_media_id, :content_type])
        )

      {:error, _reason} ->
        attrs
        |> create_provider_media_asset()
        |> handle_create_conflict(provider, source_url, content_sha256)
    end
  end

  @spec handle_create_conflict(
          {:ok, ProviderMediaAsset.t()} | {:error, Ecto.Changeset.t()},
          String.t(),
          String.t(),
          String.t()
        ) :: {:ok, ProviderMediaAsset.t()} | {:error, Ecto.Changeset.t()}
  defp handle_create_conflict({:ok, asset}, _provider, _source_url, _content_sha256),
    do: {:ok, asset}

  defp handle_create_conflict(
         {:error, %Ecto.Changeset{} = changeset},
         provider,
         source_url,
         content_sha256
       ) do
    if content_identity_conflict?(changeset) do
      case fetch_by_content(provider, source_url, content_sha256) do
        {:ok, winner} -> {:ok, winner}
        {:error, _reason} -> {:error, changeset}
      end
    else
      {:error, changeset}
    end
  end

  # Detects the specific composite-unique-constraint violation declared by
  # `ProviderMediaAsset.changeset/2`'s
  # `unique_constraint([:organization_id, :provider, :source_url,
  # :content_sha256], name: :provider_media_assets_org_provider_url_hash_index)`
  # — as opposed to any other validation/constraint error the insert could
  # have failed with, which must still surface to the caller.
  @spec content_identity_conflict?(Ecto.Changeset.t()) :: boolean()
  defp content_identity_conflict?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_message, opts}} ->
      Keyword.get(opts, :constraint) == :unique and
        Keyword.get(opts, :constraint_name) ==
          "provider_media_assets_org_provider_url_hash_index"
    end)
  end

  @doc """
  Self-healing invalidation (ADR-017 Consequences / PRD-005 T22): deletes the
  cached mapping for this content identity so the next resolve re-uploads.
  A no-op (still returns `:ok`) if nothing was cached — invalidating a miss
  is not an error.
  """
  @spec invalidate(String.t(), String.t(), String.t()) :: :ok
  def invalidate(provider, source_url, content_sha256) do
    case fetch_by_content(provider, source_url, content_sha256) do
      {:ok, asset} ->
        {:ok, _deleted} = delete_provider_media_asset(asset)
        :ok

      {:error, _reason} ->
        :ok
    end
  end
end
