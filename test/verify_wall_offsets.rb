# frozen_string_literal: true

require 'json'
require_relative '../extension/sbr_architecture/layout'
require_relative '../extension/sbr_architecture/composition'
require_relative '../extension/sbr_architecture/openings'
require_relative '../extension/sbr_architecture/palette'

module Higeotoko::SbrArchitecture
  FRAMING = %w[column beam].freeze
  module Catalog
    SYSTEMS = { 'timber' => '木造' }.freeze
  end
end

api = Higeotoko::SbrArchitecture
layout = api::Layout
points = [[0, 0], [3000, 0]]
settings = layout.wall_parameters(nil, 2700, layout::ECCENTRIC, outer: 95, inner: 55)
raise 'Total thickness is wrong' unless settings['thickness'] == 150
right = layout.wall_profile_for(settings.merge('points' => points)).first
raise 'Outside and inside faces are misplaced' unless right.map(&:last) == [55, -95, -95, 55]
left = layout.wall_profile_for(settings.merge('points' => points, 'outside_side' => 'left')).first
raise 'Outside was not flipped around the same baseline' unless left.map(&:last) == [95, -55, -55, 95]
offset = layout.wall_parameters(nil, 2700, layout::ECCENTRIC, outer: 140, inner: -20)
raise 'Entirely offset wall straddled the axis' unless layout.wall_profile_for(offset.merge('points' => points)).first.map(&:last) ==
                                                     [-20, -140, -140, -20]
begin
  layout.wall_parameters(nil, 2700, layout::ECCENTRIC, outer: 60, inner: -60)
  raise 'Zero thickness was accepted'
rescue ArgumentError => e
  raise unless e.message.include?('壁厚')
end

loop = [[0, 0], [3000, 0], [3000, 2200], [0, 2200], [0, 0]]
first = layout.wall_profile_for(settings.merge('points' => loop))
reverse = layout.wall_profile_for(settings.merge('points' => loop.reverse))
raise 'Reversing a loop changed the automatic exterior' unless first.flatten(1).sort == reverse.flatten(1).sort
raise 'Exterior corner is not closed' unless first.first.first(2) == first.last.last(2).reverse
raise 'Reference line points changed' unless loop.first == [0, 0] && loop[1] == [3000, 0]
%w[中央 左寄せ 右寄せ].each do |alignment|
  old = { 'alignment' => alignment, 'thickness' => 150, 'points' => points }
  raise 'Legacy wall alignment changed' unless layout.wall_profile_for(old) == layout.wall_profiles(points, 150, alignment)
end

window = api::Openings.parameters('window', { 'width' => 900, 'height' => 1100, 'sill' => 800 })
raise 'Automatic sash did not inherit the wall exterior' unless api::Openings.window_anchor(window, 95, -55, points, outside: 'left') == [95, 1]
window['mounting']['side'] = 'right'
raise 'Explicit sash side was overridden' unless api::Openings.window_anchor(window, 95, -55, points, outside: 'left') == [-55, -1]

palette = api::Palette.new
layers = [{ 'name' => '躯体', 'thickness' => 105, 'pattern' => 'diag' },
          { 'name' => '仕上', 'thickness' => 45, 'pattern' => 'diag' }]
values = { 'alignment' => layout::ECCENTRIC, 'outer_offset' => '95', 'inner_offset' => '999', 'height' => '2700', 'outside_side' => 'right' }
layered = palette.params_from('wall', 'timber', values, layer_rows: layers)
raise 'Layer totals were changed by a submitted inner offset' unless layered.values_at('thickness', 'outer_offset', 'inner_offset') == [150, 95, 55]
raise 'Layer bands no longer meet' unless api::Composition.bands(layered).map { |_, _, from, to| [from, to] } == [[0, 105], [105, 150]]
centered = palette.params_from('wall', 'timber', values.merge('alignment' => '中央'), layered, layer_rows: layers)
raise 'Switching modes retained eccentric placement' if centered.key?('outer_offset')

if ARGV.first
  forms = { ordinary: palette.schema('wall', 'timber'), layered: palette.schema('wall', 'timber', layered) }
  File.write(ARGV.first, JSON.generate(forms), encoding: 'UTF-8')
end
puts 'Eccentric wall offsets, exterior sides, corners, legacy alignment, layers and sash placement passed'
