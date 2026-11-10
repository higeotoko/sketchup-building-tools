# frozen_string_literal: true

%w[layout column_cuts slab_openings stairs].each do |name|
  require_relative "../extension/sbr_architecture/#{name}"
end

api = Higeotoko::SbrArchitecture
opening = { 'corners' => [[800, 1200], [4400, 2200]] }
outline = [[0, 0], [7000, 0], [7000, 4500], [0, 4500]]
rings = api::SlabOpenings.rings({ 'floor_openings' => [opening] }, outline)
raise 'The hole must preserve the rectangular footprint' unless rings.first == [[800, 1200], [4400, 1200], [4400, 2200], [800, 2200]]
raise 'Net slab area must subtract the opening' unless api::SlabOpenings.net_area({ 'points' => outline, 'floor_openings' => [opening] }) == 27_900_000

[{ 'floor_openings' => [opening, opening] }, { 'floor_openings' => [{ 'corners' => [[0, 200], [1000, 1000]] }] }].each do |bad|
  begin
    api::SlabOpenings.rings(bad, outline)
    raise 'An overlapping or boundary-touching hole was accepted'
  rescue ArgumentError
    # Invalid geometry must be rejected before creating the slab.
  end
end

params = api::Stairs.dimensions(opening.fetch('corners'), 'x+', 2940, 17).merge('risers' => 17)
raise 'Stair dimensions differ from the opening' unless params.values_at('run', 'width', 'going') == [3600, 1000, 223.75]
profile = api::Stairs.profile(params)
raise 'The stair must reach the top floor at the edge of the opening' unless profile[-2] == [3600, 2940]
raise 'The stair profile has duplicate points' unless profile.size == profile.uniq.size
puts 'Floor opening clearance, stair rise, going and landing checks passed'
