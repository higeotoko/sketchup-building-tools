# frozen_string_literal: true

%w[layout column_cuts roof room_boundaries].each do |name|
  require_relative "../extension/sbr_architecture/#{name}"
end

api = Higeotoko::SbrArchitecture
outline = [[0, 0], [6000, 0], [6000, 5000], [0, 5000], [0, 0]]
exterior = api::Layout.wall_profiles(outline, 200, '中央')
partition = api::Layout.wall_profiles([[0, 2500], [6000, 2500]], 100, '中央')
void = [[1000, 500], [2000, 500], [2000, 1500], [1000, 1500]]
layout = api::RoomBoundaries.new(exterior + partition, [void])
south = layout.region_at([3000, 1000])
north = layout.region_at([3000, 3500])
raise 'A continuous partition must divide the floor' unless south && north && south != north
raise 'Opening must be subtracted from the room' unless layout.area(south) == 5800 * 2350 - 1_000_000
raise 'The other room must retain its full area' unless layout.area(north) == 5800 * 2350
raise 'Outside, wall and void are not valid seeds' if [[-300, 1000], [3000, 2500], [1500, 1000]].any? { |point| layout.region_at(point) }
unclosed = api::RoomBoundaries.new(exterior.first(3))
raise 'An unclosed room must be rejected' if unclosed.region_at([3000, 3500])
partial = [[1000, 2100], [2000, 2100], [2000, 2700], [1000, 2700]]
joined = api::RoomBoundaries.new(exterior + partition, [partial])
raise 'Subtract only the part of an opening in this room' unless joined.area(joined.region_at([3000, 1000])) == 5800 * 2350 - 350_000
puts 'Room boundaries, partition junctions and floor opening deductions passed'
