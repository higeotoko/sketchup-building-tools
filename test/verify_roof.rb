# frozen_string_literal: true

require_relative '../extension/sbr_architecture/layout'
require_relative '../extension/sbr_architecture/roof'

roof = Higeotoko::SbrArchitecture::Roof
gable = roof.parameters({}).merge('end' => [-7200, -5400])
ends = roof.surface_ends(gable)
raise 'Gable overhang or ridge is incorrect' unless ends == [
  [[-7650.0, -5850.0, 2700.0], [-7650.0, -2700.0, 3960.0], [-7650.0, 450.0, 2700.0]],
  [[450.0, -5850.0, 2700.0], [450.0, -2700.0, 3960.0], [450.0, 450.0, 2700.0]]
]
shed = roof.parameters('roof_type' => 'shed', 'rise_direction' => 'x-', 'overhang' => 0, 'pitch' => 3.5)
raise 'Shed high edge points in the wrong direction' unless roof.surface_ends(shed.merge('end' => [4000, 3000])).first == [[0.0, 0.0, 4100.0], [4000.0, 0.0, 2700.0]]
planes = [[0.5, 0, 2500], [-0.5, 0, 4500]]
wall = [[0, 0], [4000, 0], [4000, 150], [0, 150]]
caps = roof.roof_caps(planes, wall)
raise 'A wall crossing the ridge needs two caps' unless caps.size == 2 && caps.all? { |cap| cap.size == 4 }
raise 'The ridge must be shared by the side and roof caps' unless roof.roof_edge(planes, wall[0], wall[1]) == [[0, 0], [2000.0, 0.0], [4000, 0]]
slice = planes.reduce(wall) { |profile, plane| roof.clip_profile(profile) { |point| roof.plane_height(plane, point) - 3000 } }
raise 'The high plan cut should show only the central part of the wall' unless slice.map(&:first).minmax == [1000.0, 3000.0]
[{ 'pitch' => 0 }, { 'overhang' => -1 }, { 'thickness' => 0 }, { 'rise_direction' => 'z+' }].each do |bad|
  begin
    roof.parameters(bad)
    raise "Invalid roof parameters were accepted: #{bad}"
  rescue ArgumentError
    # An invalid input must never reach geometry creation.
  end
end
puts 'Roof settings, signed corners, overhang and slope checks passed'
