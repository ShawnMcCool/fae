defmodule Fae.Credo.Check.UnlocalizedDateTimeTest do
  use Credo.Test.Case, async: false

  alias Fae.Credo.Check.UnlocalizedDateTime

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  test "flags Calendar.strftime in a web module" do
    """
    defmodule FaeWeb.Foo do
      def f(dt), do: Calendar.strftime(dt, "%Y-%m-%d")
    end
    """
    |> to_source_file("lib/fae_web/foo.ex")
    |> run_check(UnlocalizedDateTime)
    |> assert_issue()
  end

  test "flags DateTime.to_iso8601 in a web module" do
    """
    defmodule FaeWeb.Foo do
      def f(dt), do: DateTime.to_iso8601(dt)
    end
    """
    |> to_source_file("lib/fae_web/foo.ex")
    |> run_check(UnlocalizedDateTime)
    |> assert_issue()
  end

  test "does not flag the TimeDisplay module itself" do
    """
    defmodule FaeWeb.TimeDisplay do
      def f(dt), do: Calendar.strftime(dt, "%Y-%m-%d")
    end
    """
    |> to_source_file("lib/fae_web/time_display.ex")
    |> run_check(UnlocalizedDateTime)
    |> refute_issues()
  end

  test "does not flag domain (non-web) modules" do
    """
    defmodule Fae.Backups.Packager do
      def f(dt), do: Calendar.strftime(dt, "%Y-%m-%d")
    end
    """
    |> to_source_file("lib/fae/backups/packager.ex")
    |> run_check(UnlocalizedDateTime)
    |> refute_issues()
  end

  test "passes clean web code that uses TimeDisplay" do
    """
    defmodule FaeWeb.Foo do
      def f(dt, tz), do: FaeWeb.TimeDisplay.format(dt, tz, :datetime)
    end
    """
    |> to_source_file("lib/fae_web/foo.ex")
    |> run_check(UnlocalizedDateTime)
    |> refute_issues()
  end
end
