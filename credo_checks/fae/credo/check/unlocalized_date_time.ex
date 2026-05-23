defmodule Fae.Credo.Check.UnlocalizedDateTime do
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      All user-facing dates/times must render in the user's timezone via
      FaeWeb.TimeDisplay — `<.local_datetime>`, `<.relative_time>`, or
      `TimeDisplay.format/3`.

      Calling `Calendar.strftime` or `DateTime.to_iso8601` directly under
      `lib/fae_web` bypasses the timezone guard-rail and risks showing a
      raw UTC value to the user.
      """
    ]

  @forbidden [
    {[:Calendar], :strftime},
    {[:DateTime], :to_iso8601}
  ]

  @impl true
  def run(%Credo.SourceFile{} = source_file, params) do
    if scoped?(source_file.filename) do
      issue_meta = IssueMeta.for(source_file, params)
      Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
    else
      []
    end
  end

  # Only files under lib/fae_web, and never TimeDisplay itself.
  defp scoped?(filename) do
    String.contains?(filename, "lib/fae_web/") and
      not String.ends_with?(filename, "time_display.ex")
  end

  for {mod, fun} <- @forbidden do
    trigger = Enum.join(mod, ".") <> "." <> Atom.to_string(fun)

    defp traverse(
           {{:., meta, [{:__aliases__, _, unquote(mod)}, unquote(fun)]}, _, _args} = ast,
           issues,
           issue_meta
         ) do
      {ast, [issue_for(meta[:line], unquote(trigger), issue_meta) | issues]}
    end
  end

  defp traverse(ast, issues, _issue_meta), do: {ast, issues}

  defp issue_for(line_no, trigger, issue_meta) do
    format_issue(
      issue_meta,
      message: "Use FaeWeb.TimeDisplay instead of #{trigger} for user-facing dates/times.",
      trigger: trigger,
      line_no: line_no
    )
  end
end
