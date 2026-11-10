# frozen_string_literal: true

require_relative '../extension/sbr_architecture/column_cuts'
require_relative '../extension/sbr_architecture/layer_hatches'

cuts = Higeotoko::SbrArchitecture::ColumnCuts
hatches = Higeotoko::SbrArchitecture::LayerHatches
outer = [[0.0, 0.0], [100.0, 0.0], [100.0, 100.0], [0.0, 100.0]]
bore = [[10.0, 10.0], [90.0, 10.0], [90.0, 90.0], [10.0, 90.0]]
edges = [outer, bore].flat_map { |loop| loop.zip(loop.rotate) }
paths = cuts.closed_loops((edges + [edges.first.reverse]).reverse)
raise 'Outer and inner loops must survive unordered edges' unless paths.map { |loop| cuts.signed_area(loop).abs }.sort == [6400, 10000]

mask = cuts.masks([[outer, paths, edges]])
raise 'Line inside bore should be masked' unless cuts.clip([40, 50], [60, 50], mask).empty?
expected = [[[-25.0, 50.0], [0.0, 50.0]], [[100.0, 50.0], [125.0, 50.0]]]
raise 'Crossing line was not split around column' unless cuts.clip([-25, 50], [125, 50], mask) == expected
raise 'Crossing wall edge must get a plan projection' unless cuts.intersects?([-25, 50], [125, 50], mask)
raise 'A wall edge inside the outline must get a plan projection' unless cuts.intersects?([40, 50], [60, 50], mask)
raise 'A wall edge outside the outline needs no replacement' if cuts.intersects?([-25, 150], [125, 150], mask)
raise 'A wall edge touching only a corner needs no replacement' if cuts.intersects?([-25, 25], [25, -25], mask)
raise 'Unrelated line was changed' unless cuts.clip([-25, 150], [125, 150], mask) == [[[-25, 150], [125, 150]]]
layer_mask = [cuts.mask_for(paths)]
expected_with_void = [expected.first, [[10.0, 50.0], [90.0, 50.0]], expected.last]
clipped = cuts.clip([-25, 50], [125, 50], layer_mask).map do |segment|
  segment.map { |point| point.map { |value| value.round(6) } }
end
raise 'Beam graphic in a layer opening must survive' unless clipped == expected_with_void
hatches.lines(edges, 45, spacing: 32).each do |a, b|
  midpoint = a.zip(b).map { |x, y| (x + y) / 2 }
  raise 'Hatch crosses the bore' if cuts.contains?(bore, midpoint)
end
puts 'Column cut outline, bore, mask and hatch checks passed'
