# frozen_string_literal: true

require 'json'

PAGE_USE_CAMERA = 1
PAGE_USE_SECTION_PLANES = 2
PAGE_USE_LAYER_VISIBILITY = 4
PAGE_USE_HIDDEN_OBJECTS = 8
PAGE_USE_RENDERING_OPTIONS = 16

require_relative '../extension/sbr_architecture/layout'
require_relative '../extension/sbr_architecture/column_cuts'
require_relative '../extension/sbr_architecture/framing_plan'
require_relative '../extension/sbr_architecture/drawings'
require_relative '../extension/sbr_architecture/layout_sheets'

class Numeric
  def to_mm = self
end

module Higeotoko::SbrArchitecture
  def self.levels(_model) = { '1FL' => 450, '2FL' => 3450 }
  def self.point(*coordinates) = coordinates

  module Follow
    def self.kind(group) = group.kind
  end
end

api = Higeotoko::SbrArchitecture
framing = api::FramingPlan
drawings = api::Drawings
level = '2FL'
plan = drawings.spec(nil, { 'kind' => 'plan', 'level' => level, 'cut' => 1100 })
spec = drawings.spec(nil, { 'kind' => 'framing', 'level' => level, 'top_offset' => '-180', 'scale' => '100' })
raise 'General plan identity changed' unless plan['key'] == 'plan:2FL'
raise 'Framing plan identity collided' unless spec['key'] == 'framing:2FL' && drawings.title(spec) == '梁伏図 2FL'
raise 'Framing settings did not round trip' unless spec == drawings.spec(nil, JSON.parse(JSON.generate(spec)))
raise 'Framing settings did not persist' unless spec.values_at('top_offset', 'top_tolerance', 'scale') == [-180, 150, 100]
begin
  drawings.spec(nil, spec.merge('top_tolerance' => -1))
  raise 'Accepted a negative tolerance'
rescue ArgumentError
end

visible_tag = Struct.new(:visible?).new(true)
hidden_tag = Struct.new(:visible?).new(false)
max = Struct.new(:z)
box = Struct.new(:max, :valid?)
group = Struct.new(:persistent_id, :kind, :layer, :bounds)
model_groups = [
  group.new(1, 'beam', visible_tag, box.new(max.new(3270), true)),
  group.new(2, 'beam', visible_tag, box.new(max.new(3120), true)),
  group.new(3, 'beam', visible_tag, box.new(max.new(3420), true)),
  group.new(4, 'beam', visible_tag, box.new(max.new(3421), true)),
  group.new(5, 'beam', visible_tag, box.new(max.new(450), true)),
  group.new(6, 'beam', hidden_tag, box.new(max.new(3270), true)),
  group.new(7, 'beam', visible_tag, box.new(max.new(3270), true)),
  group.new(8, 'column', visible_tag, box.new(max.new(3270), true)),
  group.new(9, 'beam', visible_tag, box.new(nil, false))
]
raise 'Framing height or visibility filter failed' unless framing.select_beams(model_groups, 3270, 150, [7]).map(&:persistent_id) == [1, 2, 3]

points = [[0, 100], [100, 0], [3000, 2900], [2900, 3000], [1500, 1500]]
outline = framing.hull(points)
raise 'Diagonal beam footprint became a bounding rectangle' unless outline.sort == points.first(4).sort
entities = Class.new(Array) { def add_text(text, point) = self << [text, point] }.new
label = framing.section_label('width' => 105, 'depth' => 240)
raise 'Wrong rectangular section label' unless label == '105×240'
raise 'Lost steel designation' unless framing.section_label('section_id' => 'H-300x150x6.5x9') == 'H-300x150x6.5x9'
mask = api::ColumnCuts.mask_for([outline])
[50, 100].each do |scale|
  count = framing.draw_labels(entities, [[label, [[50, 50], [2950, 2950]], outline]], 3270, scale, [mask])
  raise 'Diagonal beam rejected its own label' unless count == 1
  raise 'Wrong text or elevation' unless entities.last[0] == label && entities.last[1].last == 3269.75
end
puts 'Framing view identity, beam filtering, slanted outlines and paper labels passed'
