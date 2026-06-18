-- Pure helper for the extender's "Use video" gate, ported from
-- apps/plugins/reaper-plugin/src/main/reaper/video-coverage.ts. Given the video
-- items overlapping forward from the extension window's start, compute how far
-- the composite covers without a gap.

local vc = {}

-- intervals: array of { start = sec, finish = sec }. Returns
-- { has_any_video, coverage_end, max_gap_free } (seconds).
function vc.compute(intervals, window_start)
  local sorted = {}
  for _, iv in ipairs(intervals) do sorted[#sorted + 1] = iv end
  table.sort(sorted, function(a, b) return a.start < b.start end)

  local reach = window_start
  local has_any = false
  for _, iv in ipairs(sorted) do
    if iv.finish > window_start then
      if iv.start > reach + 1e-3 then break end -- gap: later video is unreachable
      has_any = true -- gap-free reachable video forward from the window start
      if iv.finish > reach then reach = iv.finish end
    end
  end
  return {
    has_any_video = has_any,
    coverage_end = reach,
    max_gap_free = math.max(0, reach - window_start),
  }
end

return vc
