defmodule Glific.Providers.Swiftchat.MediaTest do
  @moduledoc """
  Covers `Glific.Providers.Swiftchat.Media` (PRD-005 T22, ADR-017):
  URL -> media-id resolution (upload-on-miss / cache-on-success) and the
  self-healing retry-once-exactly bound (GL-002 — tested against a
  simulated provider error, not just mocked-green).
  """
  use Glific.DataCase, async: false

  alias Glific.{
    Fixtures,
    Partners,
    Partners.Provider,
    Providers.MediaAssets,
    Providers.Swiftchat.Media,
    Repo
  }

  @source_url "https://example.com/media/resolve-test.jpg"
  @content "fake image bytes"
  @content_sha256 :crypto.hash(:sha256, @content) |> Base.encode16(case: :lower)
  @content_type "image/jpeg"

  @spec activate_swiftchat(non_neg_integer()) :: :ok
  defp activate_swiftchat(organization_id) do
    {:ok, swiftchat_provider} = Repo.fetch_by(Provider, %{shortcode: "swiftchat"})

    {:ok, _credential} =
      Partners.create_credential(%{
        organization_id: organization_id,
        shortcode: "swiftchat",
        keys: %{
          handler: "Glific.Providers.Swiftchat.Message",
          worker: "Glific.Providers.Swiftchat.Worker"
        },
        secrets: %{
          "api_key" => "test_swiftchat_api_key",
          "bot_id" => "test_bot_id",
          "merchant_id" => "test_merchant_id"
        },
        is_active: true
      })

    organization = Partners.get_organization!(organization_id)
    Partners.update_organization(organization, %{bsp_id: swiftchat_provider.id})

    organization = Partners.get_organization!(organization_id)
    Partners.remove_organization_cache(organization.id, organization.shortcode)
    Partners.fill_cache(organization)
    :ok
  end

  # Starts an Agent counting calls, and returns a mock fn that increments it
  # and returns `upload_response.()` — used to assert exactly-once/no-loop
  # bounds rather than just eyeballing "it passed".
  @spec start_call_counter() :: pid()
  defp start_call_counter do
    {:ok, agent} = Agent.start_link(fn -> 0 end)
    agent
  end

  @spec count(pid()) :: non_neg_integer()
  defp count(agent), do: Agent.get(agent, & &1)

  describe "resolve_media_id/4" do
    test "uploads on a cache miss and caches the returned id", attrs do
      :ok = activate_swiftchat(attrs.organization_id)
      upload_calls = start_call_counter()

      Tesla.Mock.mock(fn
        %{method: :get, url: @source_url} ->
          %Tesla.Env{status: 200, body: @content}

        %{method: :post, url: url} ->
          assert url == "https://v1-api.swiftchat.ai/api/bots/test_bot_id/media"
          Agent.update(upload_calls, &(&1 + 1))
          %Tesla.Env{status: 201, body: Jason.encode!(%{"id" => "provider-media-id-uploaded"})}
      end)

      assert {:ok, "provider-media-id-uploaded"} =
               Media.resolve_media_id(attrs.organization_id, @source_url, @content_type)

      assert count(upload_calls) == 1

      assert {:ok, asset} =
               MediaAssets.fetch_by_content("swiftchat", @source_url, @content_sha256)

      assert asset.provider_media_id == "provider-media-id-uploaded"
      assert asset.content_type == @content_type
    end

    test "returns the cached id on a hit without re-uploading", attrs do
      :ok = activate_swiftchat(attrs.organization_id)

      Fixtures.provider_media_asset_fixture(
        Map.merge(attrs, %{
          provider: "swiftchat",
          source_url: @source_url,
          content_sha256: @content_sha256,
          provider_media_id: "provider-media-id-cached"
        })
      )

      Tesla.Mock.mock(fn
        %{method: :get, url: @source_url} ->
          %Tesla.Env{status: 200, body: @content}

        %{method: :post} ->
          flunk("cache hit should not have triggered an upload")
      end)

      assert {:ok, "provider-media-id-cached"} =
               Media.resolve_media_id(attrs.organization_id, @source_url, @content_type)
    end

    test "rejects content over the 64 MB cap without uploading", attrs do
      :ok = activate_swiftchat(attrs.organization_id)
      oversize_content = :binary.copy(<<0>>, 64 * 1024 * 1024 + 1)

      Tesla.Mock.mock(fn
        %{method: :get, url: @source_url} ->
          %Tesla.Env{status: 200, body: oversize_content}

        %{method: :post} ->
          flunk("oversize content should not have triggered an upload")
      end)

      assert {:error, error_msg} =
               Media.resolve_media_id(attrs.organization_id, @source_url, @content_type)

      assert error_msg =~ "exceeds the 64 MB SwiftChat limit"
    end

    test "propagates a fetch failure without ever calling upload", attrs do
      :ok = activate_swiftchat(attrs.organization_id)

      Tesla.Mock.mock(fn
        %{method: :get, url: @source_url} ->
          {:error, :timeout}

        %{method: :post} ->
          flunk("a failed fetch should not have triggered an upload")
      end)

      assert {:error, error_msg} =
               Media.resolve_media_id(attrs.organization_id, @source_url, @content_type)

      assert error_msg =~ "Could not fetch media"
    end

    test "force_reupload: true invalidates the existing mapping and re-uploads", attrs do
      :ok = activate_swiftchat(attrs.organization_id)

      Fixtures.provider_media_asset_fixture(
        Map.merge(attrs, %{
          provider: "swiftchat",
          source_url: @source_url,
          content_sha256: @content_sha256,
          provider_media_id: "provider-media-id-stale"
        })
      )

      upload_calls = start_call_counter()

      Tesla.Mock.mock(fn
        %{method: :get, url: @source_url} ->
          %Tesla.Env{status: 200, body: @content}

        %{method: :post} ->
          Agent.update(upload_calls, &(&1 + 1))
          %Tesla.Env{status: 201, body: Jason.encode!(%{"id" => "provider-media-id-fresh"})}
      end)

      assert {:ok, "provider-media-id-fresh"} =
               Media.resolve_media_id(attrs.organization_id, @source_url, @content_type, true)

      assert count(upload_calls) == 1

      assert {:ok, asset} =
               MediaAssets.fetch_by_content("swiftchat", @source_url, @content_sha256)

      assert asset.provider_media_id == "provider-media-id-fresh"
    end

    test "self-scopes from the explicit organization_id even when the process's org context is stale/mis-set",
         attrs do
      :ok = activate_swiftchat(attrs.organization_id)

      # A different org, deliberately left as the process's CURRENT org
      # context — simulating a reused process (e.g. a pooled worker) whose
      # process dictionary still points at whatever org it last handled.
      # `resolve_media_id/4` must not trust this; it must (re)scope itself
      # from its own explicit `organization_id` argument (the ADR-017
      # Oban-worker precondition made structural).
      other_organization = Fixtures.organization_fixture()
      Repo.put_organization_id(other_organization.id)
      assert Repo.get_organization_id() == other_organization.id
      assert other_organization.id != attrs.organization_id

      Tesla.Mock.mock(fn
        %{method: :get, url: @source_url} ->
          %Tesla.Env{status: 200, body: @content}

        %{method: :post} ->
          %Tesla.Env{status: 201, body: Jason.encode!(%{"id" => "provider-media-id-scoped"})}
      end)

      assert {:ok, "provider-media-id-scoped"} =
               Media.resolve_media_id(attrs.organization_id, @source_url, @content_type)

      # Lands under the EXPLICIT org passed to resolve_media_id/4, not the
      # stale org that was in the process dictionary beforehand.
      Repo.put_organization_id(attrs.organization_id)

      assert {:ok, asset} =
               MediaAssets.fetch_by_content("swiftchat", @source_url, @content_sha256)

      assert asset.provider_media_id == "provider-media-id-scoped"
      assert asset.organization_id == attrs.organization_id

      # And is NOT visible under the stale org's scope — confirming this
      # isn't just "found somewhere," it is scoped to the right tenant.
      Repo.put_organization_id(other_organization.id)

      assert {:error, _reason} =
               MediaAssets.fetch_by_content("swiftchat", @source_url, @content_sha256)
    end
  end

  describe "send_with_media_id/4 (self-healing hook, GL-002)" do
    test "calls send_fn once with the resolved id on a normal successful send", attrs do
      :ok = activate_swiftchat(attrs.organization_id)
      send_calls = start_call_counter()

      Tesla.Mock.mock(fn
        %{method: :get, url: @source_url} ->
          %Tesla.Env{status: 200, body: @content}

        %{method: :post} ->
          %Tesla.Env{status: 201, body: Jason.encode!(%{"id" => "provider-media-id-uploaded"})}
      end)

      send_fn = fn media_id ->
        Agent.update(send_calls, &(&1 + 1))
        assert media_id == "provider-media-id-uploaded"
        {:ok, :sent}
      end

      assert {:ok, :sent} =
               Media.send_with_media_id(
                 attrs.organization_id,
                 @source_url,
                 @content_type,
                 send_fn
               )

      assert count(send_calls) == 1
    end

    test "self-scopes from the explicit organization_id even when the process's org context is stale/mis-set",
         attrs do
      :ok = activate_swiftchat(attrs.organization_id)

      other_organization = Fixtures.organization_fixture()
      Repo.put_organization_id(other_organization.id)
      assert Repo.get_organization_id() == other_organization.id
      assert other_organization.id != attrs.organization_id

      Tesla.Mock.mock(fn
        %{method: :get, url: @source_url} ->
          %Tesla.Env{status: 200, body: @content}

        %{method: :post} ->
          %Tesla.Env{status: 201, body: Jason.encode!(%{"id" => "provider-media-id-scoped"})}
      end)

      send_fn = fn media_id ->
        assert media_id == "provider-media-id-scoped"
        {:ok, :sent}
      end

      assert {:ok, :sent} =
               Media.send_with_media_id(
                 attrs.organization_id,
                 @source_url,
                 @content_type,
                 send_fn
               )

      Repo.put_organization_id(attrs.organization_id)

      assert {:ok, asset} =
               MediaAssets.fetch_by_content("swiftchat", @source_url, @content_sha256)

      assert asset.provider_media_id == "provider-media-id-scoped"
      assert asset.organization_id == attrs.organization_id
    end

    test "a synthetic code-4 'Invalid media ID' response triggers exactly one re-upload and one retry, then succeeds",
         attrs do
      :ok = activate_swiftchat(attrs.organization_id)

      Fixtures.provider_media_asset_fixture(
        Map.merge(attrs, %{
          provider: "swiftchat",
          source_url: @source_url,
          content_sha256: @content_sha256,
          provider_media_id: "provider-media-id-stale"
        })
      )

      upload_calls = start_call_counter()
      send_calls = start_call_counter()

      Tesla.Mock.mock(fn
        %{method: :get, url: @source_url} ->
          %Tesla.Env{status: 200, body: @content}

        %{method: :post} ->
          Agent.update(upload_calls, &(&1 + 1))
          %Tesla.Env{status: 201, body: Jason.encode!(%{"id" => "provider-media-id-fresh"})}
      end)

      send_fn = fn media_id ->
        call_number = Agent.get_and_update(send_calls, &{&1, &1 + 1})

        case call_number do
          0 ->
            assert media_id == "provider-media-id-stale"
            {:error, %{"code" => 4, "message" => "Invalid media ID"}}

          1 ->
            assert media_id == "provider-media-id-fresh"
            {:ok, :sent}
        end
      end

      assert {:ok, :sent} =
               Media.send_with_media_id(
                 attrs.organization_id,
                 @source_url,
                 @content_type,
                 send_fn
               )

      # exactly one re-upload (the cache-hit branch never uploads on the
      # first attempt — this upload is entirely the self-healing retry) and
      # exactly two send attempts (original + the one bounded retry).
      assert count(upload_calls) == 1
      assert count(send_calls) == 2

      assert {:ok, asset} =
               MediaAssets.fetch_by_content("swiftchat", @source_url, @content_sha256)

      assert asset.provider_media_id == "provider-media-id-fresh"
    end

    test "GL-002: a persistently-invalid media id retries exactly once, then returns the error — no crash, no loop",
         attrs do
      :ok = activate_swiftchat(attrs.organization_id)

      Fixtures.provider_media_asset_fixture(
        Map.merge(attrs, %{
          provider: "swiftchat",
          source_url: @source_url,
          content_sha256: @content_sha256,
          provider_media_id: "provider-media-id-always-stale"
        })
      )

      upload_calls = start_call_counter()
      send_calls = start_call_counter()

      Tesla.Mock.mock(fn
        %{method: :get, url: @source_url} ->
          %Tesla.Env{status: 200, body: @content}

        %{method: :post} ->
          Agent.update(upload_calls, &(&1 + 1))
          %Tesla.Env{status: 201, body: Jason.encode!(%{"id" => "provider-media-id-still-bad"})}
      end)

      send_fn = fn _media_id ->
        Agent.update(send_calls, &(&1 + 1))
        {:error, %{"code" => 4, "message" => "Invalid media ID"}}
      end

      assert {:error, %{"code" => 4}} =
               Media.send_with_media_id(
                 attrs.organization_id,
                 @source_url,
                 @content_type,
                 send_fn
               )

      # the structural bound: exactly one re-upload, exactly two send
      # attempts total, no third attempt however many times the provider
      # keeps rejecting the id.
      assert count(upload_calls) == 1
      assert count(send_calls) == 2
    end

    test "does not call send_fn at all when resolution itself fails", attrs do
      :ok = activate_swiftchat(attrs.organization_id)

      Tesla.Mock.mock(fn
        %{method: :get, url: @source_url} -> {:error, :timeout}
      end)

      send_fn = fn _media_id -> flunk("send_fn should not be called when resolution fails") end

      assert {:error, error_msg} =
               Media.send_with_media_id(
                 attrs.organization_id,
                 @source_url,
                 @content_type,
                 send_fn
               )

      assert error_msg =~ "Could not fetch media"
    end
  end
end
