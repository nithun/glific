defmodule Glific.Providers.MediaAssetsTest do
  @moduledoc """
  Covers `Glific.Providers.MediaAssets` (PRD-005 T20, ADR-017): CRUD on the
  org-scoped provider-media-asset registry, the content-identity lookup
  used by resolution (T22), and the multi-tenancy boundary (L-002).
  """
  use Glific.DataCase, async: true

  alias Ecto.Adapters.SQL.Sandbox

  alias Glific.{
    Fixtures,
    Providers.MediaAssets,
    Providers.MediaAssets.ProviderMediaAsset
  }

  @sha256_a String.duplicate("a", 64)
  @sha256_b String.duplicate("b", 64)

  describe "provider_media_assets" do
    test "list_provider_media_assets/1 returns all assets for the org", attrs do
      asset = Fixtures.provider_media_asset_fixture(attrs)

      assert MediaAssets.list_provider_media_assets(%{filter: attrs})
             |> Enum.any?(&(&1.id == asset.id))
    end

    test "count_provider_media_assets/1 returns the count of assets for the org", attrs do
      asset_count = MediaAssets.count_provider_media_assets(%{filter: attrs})

      _asset = Fixtures.provider_media_asset_fixture(attrs)

      assert MediaAssets.count_provider_media_assets(%{filter: attrs}) == asset_count + 1
    end

    test "get_provider_media_asset!/1 returns the asset with the given id", attrs do
      asset = Fixtures.provider_media_asset_fixture(attrs)
      assert MediaAssets.get_provider_media_asset!(asset.id).id == asset.id
    end

    test "fetch_provider_media_asset/1 returns {:ok, asset} when found", attrs do
      asset = Fixtures.provider_media_asset_fixture(attrs)
      assert {:ok, fetched} = MediaAssets.fetch_provider_media_asset(asset.id)
      assert fetched.id == asset.id
    end

    test "fetch_provider_media_asset/1 returns {:error, _} when not found" do
      assert {:error, _reason} = MediaAssets.fetch_provider_media_asset(-1)
    end

    test "create_provider_media_asset/1 with valid data creates an asset", attrs do
      valid_attrs =
        Map.merge(attrs, %{
          provider: "swiftchat",
          source_url: "https://example.com/media/create.jpg",
          content_sha256: @sha256_a,
          provider_media_id: "provider-media-id-create"
        })

      assert {:ok, %ProviderMediaAsset{} = asset} =
               MediaAssets.create_provider_media_asset(valid_attrs)

      assert asset.provider == "swiftchat"
      assert asset.source_url == "https://example.com/media/create.jpg"
      assert asset.content_sha256 == @sha256_a
      assert asset.provider_media_id == "provider-media-id-create"
      assert asset.organization_id == attrs.organization_id
    end

    test "create_provider_media_asset/1 with missing required fields returns an error changeset",
         attrs do
      assert {:error, %Ecto.Changeset{}} = MediaAssets.create_provider_media_asset(attrs)
    end

    test "create_provider_media_asset/1 rejects a content_sha256 that isn't 64 hex chars",
         attrs do
      invalid_attrs =
        Map.merge(attrs, %{
          provider: "swiftchat",
          source_url: "https://example.com/media/bad-hash.jpg",
          content_sha256: "not-a-sha256",
          provider_media_id: "provider-media-id-bad-hash"
        })

      assert {:error, changeset} = MediaAssets.create_provider_media_asset(invalid_attrs)
      assert "must be a 64-character hex-encoded SHA-256" in errors_on(changeset).content_sha256
    end

    test "create_provider_media_asset/1 enforces the (org, provider, source_url, content_sha256) unique key",
         attrs do
      dup_attrs =
        Map.merge(attrs, %{
          provider: "swiftchat",
          source_url: "https://example.com/media/dup.jpg",
          content_sha256: @sha256_a,
          provider_media_id: "provider-media-id-dup-1"
        })

      assert {:ok, _asset} = MediaAssets.create_provider_media_asset(dup_attrs)

      assert {:error, changeset} =
               MediaAssets.create_provider_media_asset(
                 Map.put(dup_attrs, :provider_media_id, "provider-media-id-dup-2")
               )

      assert "has already been taken" in errors_on(changeset).organization_id
    end

    test "update_provider_media_asset/2 with valid data updates the asset", attrs do
      asset = Fixtures.provider_media_asset_fixture(attrs)

      assert {:ok, updated} =
               MediaAssets.update_provider_media_asset(asset, %{
                 provider_media_id: "provider-media-id-updated"
               })

      assert updated.provider_media_id == "provider-media-id-updated"
    end

    test "update_provider_media_asset/2 with invalid data returns an error changeset", attrs do
      asset = Fixtures.provider_media_asset_fixture(attrs)

      assert {:error, %Ecto.Changeset{}} =
               MediaAssets.update_provider_media_asset(asset, %{provider_media_id: nil})

      assert asset.provider_media_id ==
               MediaAssets.get_provider_media_asset!(asset.id).provider_media_id
    end

    test "delete_provider_media_asset/1 deletes the asset", attrs do
      asset = Fixtures.provider_media_asset_fixture(attrs)
      assert {:ok, %ProviderMediaAsset{}} = MediaAssets.delete_provider_media_asset(asset)
      assert {:error, _reason} = MediaAssets.fetch_provider_media_asset(asset.id)
    end
  end

  describe "fetch_by_content/3, put_asset/1, invalidate/3 (T22 resolution seam)" do
    test "fetch_by_content/3 finds the exact content-identity match", attrs do
      asset =
        Fixtures.provider_media_asset_fixture(
          Map.merge(attrs, %{
            provider: "swiftchat",
            source_url: "https://example.com/media/lookup.jpg",
            content_sha256: @sha256_a
          })
        )

      assert {:ok, found} =
               MediaAssets.fetch_by_content(
                 "swiftchat",
                 "https://example.com/media/lookup.jpg",
                 @sha256_a
               )

      assert found.id == asset.id
    end

    test "fetch_by_content/3 misses when the content hash differs (URL bytes changed)", attrs do
      Fixtures.provider_media_asset_fixture(
        Map.merge(attrs, %{
          provider: "swiftchat",
          source_url: "https://example.com/media/changed.jpg",
          content_sha256: @sha256_a
        })
      )

      assert {:error, _reason} =
               MediaAssets.fetch_by_content(
                 "swiftchat",
                 "https://example.com/media/changed.jpg",
                 @sha256_b
               )
    end

    test "put_asset/1 creates a new row on first upload", attrs do
      put_attrs =
        Map.merge(attrs, %{
          provider: "swiftchat",
          source_url: "https://example.com/media/put-new.jpg",
          content_sha256: @sha256_a,
          provider_media_id: "provider-media-id-1"
        })

      assert {:ok, asset} = MediaAssets.put_asset(put_attrs)
      assert asset.provider_media_id == "provider-media-id-1"
    end

    test "put_asset/1 updates the existing row in place for the same content identity (self-healing re-upload)",
         attrs do
      put_attrs =
        Map.merge(attrs, %{
          provider: "swiftchat",
          source_url: "https://example.com/media/put-existing.jpg",
          content_sha256: @sha256_a,
          provider_media_id: "provider-media-id-1"
        })

      assert {:ok, first} = MediaAssets.put_asset(put_attrs)

      assert {:ok, second} =
               MediaAssets.put_asset(
                 Map.put(put_attrs, :provider_media_id, "provider-media-id-2")
               )

      assert second.id == first.id
      assert second.provider_media_id == "provider-media-id-2"

      assert {:ok, refetched} =
               MediaAssets.fetch_by_content(
                 "swiftchat",
                 "https://example.com/media/put-existing.jpg",
                 @sha256_a
               )

      assert refetched.id == first.id
      assert refetched.provider_media_id == "provider-media-id-2"
    end

    test "put_asset/1 recovers the winning row when a concurrent insert wins the unique-constraint race",
         attrs do
      source_url = "https://example.com/media/race.jpg"

      loser_attrs =
        Map.merge(attrs, %{
          provider: "swiftchat",
          source_url: source_url,
          content_sha256: @sha256_a,
          provider_media_id: "provider-media-id-loser"
        })

      winner_attrs = Map.put(loser_attrs, :provider_media_id, "provider-media-id-winner")

      test_pid = self()

      # Simulates the sibling resolver that wins the upload-on-miss race
      # (ADR-017): a genuinely separate, real, auto-committing connection
      # (`sandbox: false` — NOT the shared sandboxed transaction the rest of
      # this test uses) inserts the winning row and holds its transaction
      # open until told to commit. Because it stays uncommitted, this row is
      # invisible (READ COMMITTED) to `put_asset/1`'s own
      # `fetch_by_content/3` pre-check no matter when that check runs, so
      # `put_asset/1` is guaranteed to attempt its own `INSERT` — which then
      # either blocks on this transaction's row lock or (once released)
      # fails outright with the real
      # `provider_media_assets_org_provider_url_hash_index` unique
      # constraint violation, exactly like two concurrent BEAM nodes would
      # race in production.
      winner_task =
        Task.async(fn ->
          :ok = Sandbox.checkout(Repo, sandbox: false)

          Repo.transaction(fn ->
            {:ok, winner} = MediaAssets.create_provider_media_asset(winner_attrs)
            send(test_pid, {:winner_inserted, winner})

            receive do
              :commit -> winner
            after
              5_000 -> raise "winner_task timed out waiting for the commit signal"
            end
          end)
        end)

      receive do
        {:winner_inserted, _winner} -> :ok
      after
        5_000 -> flunk("winner_task's insert never happened")
      end

      # Registered immediately, BEFORE any assertion below can fail: the
      # winner row was committed on a real, non-sandboxed connection, so it
      # survives this test's own sandbox rollback and must be deleted
      # explicitly regardless of how the rest of the test turns out.
      on_exit(fn ->
        :ok = Sandbox.checkout(Repo, sandbox: false)

        # `skip_organization_id: true` is safe/required here: the on_exit
        # handler runs in its own process with no org set in its process
        # dictionary, and this is purely test-cleanup for a row that was
        # deliberately committed outside the sandbox rollback above (not
        # app runtime code, not reachable from any request/worker path).
        Repo.delete_all(
          from(a in ProviderMediaAsset,
            where: a.source_url == ^source_url and a.content_sha256 == ^@sha256_a
          ),
          skip_organization_id: true
        )

        Sandbox.checkin(Repo)
      end)

      put_task =
        Task.async(fn ->
          Repo.put_organization_id(attrs.organization_id)
          MediaAssets.put_asset(loser_attrs)
        end)

      # Bounded synchronization, not a retry-poll: gives `put_task` room to
      # issue its own `fetch_by_content/3` SELECT (a single fast local
      # round trip) before the winner's row becomes visible. The miss
      # itself does not depend on this delay — an uncommitted row is never
      # visible under READ COMMITTED regardless of timing — this only
      # protects against the winner committing before `put_task` has even
      # issued that first query.
      Process.sleep(200)
      send(winner_task.pid, :commit)

      assert {:ok, winner} = Task.await(winner_task, 5_000)
      assert {:ok, recovered} = Task.await(put_task, 5_000)

      assert recovered.id == winner.id
      assert recovered.provider_media_id == "provider-media-id-winner"
    end

    test "invalidate/3 deletes the cached mapping", attrs do
      Fixtures.provider_media_asset_fixture(
        Map.merge(attrs, %{
          provider: "swiftchat",
          source_url: "https://example.com/media/invalidate.jpg",
          content_sha256: @sha256_a
        })
      )

      assert :ok =
               MediaAssets.invalidate(
                 "swiftchat",
                 "https://example.com/media/invalidate.jpg",
                 @sha256_a
               )

      assert {:error, _reason} =
               MediaAssets.fetch_by_content(
                 "swiftchat",
                 "https://example.com/media/invalidate.jpg",
                 @sha256_a
               )
    end

    test "invalidate/3 is a no-op (returns :ok) when nothing was cached" do
      assert :ok =
               MediaAssets.invalidate(
                 "swiftchat",
                 "https://example.com/media/never-cached.jpg",
                 @sha256_a
               )
    end
  end

  describe "multi-tenancy (L-002): no cross-org read" do
    test "an org cannot fetch another org's provider media asset by id", attrs do
      other_organization = Fixtures.organization_fixture()

      {:ok, other_org_asset} =
        MediaAssets.create_provider_media_asset(%{
          organization_id: other_organization.id,
          provider: "swiftchat",
          source_url: "https://example.com/media/other-org.jpg",
          content_sha256: @sha256_a,
          provider_media_id: "provider-media-id-other-org"
        })

      # `Fixtures.organization_fixture/1` calls `Partners.fill_cache/1`,
      # which switches THIS process's org context to the new org as a side
      # effect (so the fixture caller can immediately act "as" it) — restore
      # it to the DataCase default org before asserting isolation, same
      # pattern as `test/glific_web/resolvers/ai_evaluations_test.exs`.
      Repo.put_organization_id(attrs.organization_id)

      assert attrs.organization_id != other_organization.id
      assert {:error, _reason} = MediaAssets.fetch_provider_media_asset(other_org_asset.id)

      assert_raise Ecto.NoResultsError, fn ->
        MediaAssets.get_provider_media_asset!(other_org_asset.id)
      end

      refute MediaAssets.list_provider_media_assets(%{filter: attrs})
             |> Enum.any?(&(&1.id == other_org_asset.id))
    end

    test "fetch_by_content/3 does not leak another org's mapping for the same content identity",
         attrs do
      other_organization = Fixtures.organization_fixture()

      {:ok, _other_org_asset} =
        MediaAssets.create_provider_media_asset(%{
          organization_id: other_organization.id,
          provider: "swiftchat",
          source_url: "https://example.com/media/shared-url.jpg",
          content_sha256: @sha256_a,
          provider_media_id: "provider-media-id-other-org-shared"
        })

      Repo.put_organization_id(attrs.organization_id)
      assert attrs.organization_id != other_organization.id

      assert {:error, _reason} =
               MediaAssets.fetch_by_content(
                 "swiftchat",
                 "https://example.com/media/shared-url.jpg",
                 @sha256_a
               )
    end
  end
end
