defmodule Fae.Backups.JobTest do
  use Fae.DataCase, async: false

  alias Fae.Backups.{Job, Jobs}
  alias Fae.Storage.Destinations

  setup do
    {:ok, destination} =
      Destinations.create(%{
        name: "Test",
        driver: "s3",
        endpoint_url: "https://example.com",
        region: "us",
        bucket: "b",
        access_key_id: "k",
        secret_access_key: "s"
      })

    %{destination: destination}
  end

  defp base_attrs(destination, overrides \\ %{}) do
    Map.merge(
      %{
        name: "Daily Backup",
        slug: "daily-backup",
        source_kind: "file",
        source_path: "/tmp/a.txt",
        destination_id: destination.id,
        package_format: "as_is",
        recurrence_kind: "daily",
        time_of_day: "03:00",
        retention_strategy: "keep_last_n",
        retention_params: %{"n" => 7}
      },
      overrides
    )
  end

  describe "source_kind / package_format interaction" do
    test "folder + as_is is rejected", %{destination: destination} do
      attrs = base_attrs(destination, %{source_kind: "folder", package_format: "as_is"})
      changeset = Job.changeset(%Job{}, attrs)
      refute changeset.valid?

      assert "must be 'tar_gz' when source_kind is 'folder'" in errors_on(changeset).package_format
    end

    test "folder + tar_gz is accepted", %{destination: destination} do
      attrs = base_attrs(destination, %{source_kind: "folder", package_format: "tar_gz"})
      assert %Ecto.Changeset{valid?: true} = Job.changeset(%Job{}, attrs)
    end

    test "file + as_is is accepted", %{destination: destination} do
      attrs = base_attrs(destination, %{source_kind: "file", package_format: "as_is"})
      assert %Ecto.Changeset{valid?: true} = Job.changeset(%Job{}, attrs)
    end

    test "sqlite + as_is is accepted", %{destination: destination} do
      attrs = base_attrs(destination, %{source_kind: "sqlite", package_format: "as_is"})
      assert %Ecto.Changeset{valid?: true} = Job.changeset(%Job{}, attrs)
    end
  end

  describe "slug validation" do
    test "rejects uppercase letters", %{destination: destination} do
      attrs = base_attrs(destination, %{slug: "Daily-Backup"})
      changeset = Job.changeset(%Job{}, attrs)

      assert "must be lowercase letters, digits, and hyphens" in errors_on(changeset).slug
    end

    test "rejects leading hyphen", %{destination: destination} do
      attrs = base_attrs(destination, %{slug: "-backup"})
      changeset = Job.changeset(%Job{}, attrs)
      assert "must be lowercase letters, digits, and hyphens" in errors_on(changeset).slug
    end

    test "rejects underscores", %{destination: destination} do
      attrs = base_attrs(destination, %{slug: "daily_backup"})
      changeset = Job.changeset(%Job{}, attrs)
      assert "must be lowercase letters, digits, and hyphens" in errors_on(changeset).slug
    end

    test "enforces uniqueness", %{destination: destination} do
      assert {:ok, _} = Jobs.create(base_attrs(destination))
      assert {:error, changeset} = Jobs.create(base_attrs(destination))
      assert "has already been taken" in errors_on(changeset).slug
    end
  end

  describe "recurrence validation" do
    test "hourly does not require time_of_day", %{destination: destination} do
      attrs = base_attrs(destination, %{recurrence_kind: "hourly", time_of_day: nil})
      assert %Ecto.Changeset{valid?: true} = Job.changeset(%Job{}, attrs)
    end

    test "daily requires time_of_day", %{destination: destination} do
      attrs = base_attrs(destination, %{recurrence_kind: "daily", time_of_day: nil})
      changeset = Job.changeset(%Job{}, attrs)
      assert "is required for daily schedules" in errors_on(changeset).time_of_day
    end

    test "weekly requires time_of_day and day_of_week", %{destination: destination} do
      attrs =
        base_attrs(destination, %{
          recurrence_kind: "weekly",
          time_of_day: nil,
          day_of_week: nil
        })

      changeset = Job.changeset(%Job{}, attrs)
      assert "is required for weekly schedules" in errors_on(changeset).time_of_day
      assert "is required for weekly schedules" in errors_on(changeset).day_of_week
    end

    test "weekly rejects day_of_week outside 0..6", %{destination: destination} do
      attrs =
        base_attrs(destination, %{
          recurrence_kind: "weekly",
          time_of_day: "03:00",
          day_of_week: 9
        })

      changeset = Job.changeset(%Job{}, attrs)
      assert "must be between 0 (Sunday) and 6 (Saturday)" in errors_on(changeset).day_of_week
    end

    test "monthly rejects day_of_month > 28", %{destination: destination} do
      attrs =
        base_attrs(destination, %{
          recurrence_kind: "monthly",
          time_of_day: "03:00",
          day_of_month: 31
        })

      changeset = Job.changeset(%Job{}, attrs)
      assert "must be between 1 and 28" in errors_on(changeset).day_of_month
    end

    test "monthly accepts day_of_month within 1..28", %{destination: destination} do
      attrs =
        base_attrs(destination, %{
          recurrence_kind: "monthly",
          time_of_day: "03:00",
          day_of_month: 15
        })

      assert %Ecto.Changeset{valid?: true} = Job.changeset(%Job{}, attrs)
    end
  end

  describe "time_of_day format" do
    test "rejects malformed times", %{destination: destination} do
      for bad <- ~w(3am 25:00 03:60 3:00 03:0) do
        attrs = base_attrs(destination, %{time_of_day: bad})
        changeset = Job.changeset(%Job{}, attrs)
        assert "must be in HH:MM format" in errors_on(changeset).time_of_day, "for #{bad}"
      end
    end

    test "accepts well-formed times", %{destination: destination} do
      for good <- ~w(00:00 23:59 09:30 12:00) do
        attrs = base_attrs(destination, %{time_of_day: good})
        assert %Ecto.Changeset{valid?: true} = Job.changeset(%Job{}, attrs), "for #{good}"
      end
    end
  end

  describe "retention_params shape" do
    test "keep_last_n requires %{n: positive integer}", %{destination: destination} do
      attrs =
        base_attrs(destination, %{
          retention_strategy: "keep_last_n",
          retention_params: %{"days" => 7}
        })

      changeset = Job.changeset(%Job{}, attrs)
      assert "shape does not match retention_strategy" in errors_on(changeset).retention_params
    end

    test "keep_for_days requires %{days: positive integer}", %{destination: destination} do
      attrs =
        base_attrs(destination, %{
          retention_strategy: "keep_for_days",
          retention_params: %{"days" => 30}
        })

      assert %Ecto.Changeset{valid?: true} = Job.changeset(%Job{}, attrs)
    end

    test "gfs requires daily/weekly/monthly integer counts", %{destination: destination} do
      good =
        base_attrs(destination, %{
          retention_strategy: "gfs",
          retention_params: %{"daily" => 7, "weekly" => 4, "monthly" => 12}
        })

      assert %Ecto.Changeset{valid?: true} = Job.changeset(%Job{}, good)

      bad =
        base_attrs(destination, %{
          retention_strategy: "gfs",
          retention_params: %{"daily" => 7}
        })

      changeset = Job.changeset(%Job{}, bad)
      assert "shape does not match retention_strategy" in errors_on(changeset).retention_params
    end
  end

  describe "backup_rel/1" do
    test "joins prefix and slug" do
      assert Job.backup_rel(%Job{prefix: "Family", slug: "daily-db"}) == "Family/daily-db"
    end

    test "omits a blank prefix" do
      assert Job.backup_rel(%Job{prefix: "", slug: "daily-db"}) == "daily-db"
    end

    test "omits a nil prefix" do
      assert Job.backup_rel(%Job{prefix: nil, slug: "daily-db"}) == "daily-db"
    end
  end

  describe "jobs context broadcasts" do
    test "create broadcasts {:job_changed, id}", %{destination: destination} do
      Phoenix.PubSub.subscribe(Fae.PubSub, Fae.Topics.backups_jobs())
      assert {:ok, job} = Jobs.create(base_attrs(destination))
      assert_receive {:job_changed, job_id}
      assert job_id == job.id
    end

    test "update broadcasts", %{destination: destination} do
      {:ok, job} = Jobs.create(base_attrs(destination))
      Phoenix.PubSub.subscribe(Fae.PubSub, Fae.Topics.backups_jobs())
      assert {:ok, _} = Jobs.update(job, %{name: "Renamed"})
      assert_receive {:job_changed, job_id}
      assert job_id == job.id
    end

    test "delete broadcasts", %{destination: destination} do
      {:ok, job} = Jobs.create(base_attrs(destination))
      Phoenix.PubSub.subscribe(Fae.PubSub, Fae.Topics.backups_jobs())
      assert {:ok, _} = Jobs.delete(job)
      assert_receive {:job_changed, job_id}
      assert job_id == job.id
    end
  end
end
