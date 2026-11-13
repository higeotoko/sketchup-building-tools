# frozen_string_literal: true

# Drawings defines the scene flags at load time.
PAGE_USE_CAMERA = 1
PAGE_USE_SECTION_PLANES = 2
PAGE_USE_LAYER_VISIBILITY = 4
PAGE_USE_HIDDEN_OBJECTS = 8
PAGE_USE_RENDERING_OPTIONS = 16

require 'json'
require_relative '../extension/sbr_architecture/drawings'
require_relative '../extension/sbr_architecture/drawing_datums'
require_relative '../extension/sbr_architecture/column_cuts'

Scene = Struct.new(:spec, :number) do
  def get_attribute(_dictionary, key)
    { 'spec' => JSON.generate(spec), 'sheet_number' => number }.fetch(key)
  end
end

Model = Struct.new(:pages, :last_number) do
  def get_attribute(_dictionary, _key, _default)
    last_number
  end
end

drawings = Higeotoko::SbrArchitecture::Drawings
plan = { 'key' => 'plan:1FL', 'kind' => 'plan' }
a = { 'key' => 'section:A-A', 'kind' => 'section', 'name' => 'A-A', 'side' => 'x+', 'offset' => 100 }
b = { 'key' => 'section:B-B', 'kind' => 'section', 'name' => 'B-B', 'side' => 'y-', 'offset' => 200 }
model = Model.new([Scene.new(plan), Scene.new(a), Scene.new(b)], 0)
legacy = drawings.assign_sheet_numbers(model, drawings.specs(model), [plan, a, b].map { |item| item.fetch('key') })
raise 'Migration must follow legacy order' unless legacy.values == [1, 2, 3]

renamed = a.merge('name' => 'A1-A1')
model = Model.new([Scene.new(b, 3), Scene.new(plan, 1), Scene.new(renamed, 2)], 4)
raise 'Rename should keep the original scene key' unless drawings.section_key(model, renamed, renamed['name']) == a['key']
new_key = drawings.section_key(model, {}, a['name'])
raise 'The old name must not resolve to the renamed scene' if new_key == a['key']
begin
  drawings.section_key(model, renamed, b['name'])
  raise 'Duplicate section name accepted'
rescue ArgumentError => e
  raise unless e.message.include?('使用済み')
end

numbers = drawings.assign_sheet_numbers(model, drawings.specs(model), [b['key'], plan['key'], a['key'], new_key])
raise 'Reordering changed a sheet number' unless legacy.all? { |key, number| numbers[key] == number }
raise 'A deleted sheet number was reused' unless numbers[new_key] == 5
targets = drawings.section_targets([b, plan, renamed], numbers)
raise 'The plan references its own sheet' unless targets.map { |item| item['sheet'] } == %w[A-03 A-02]
raise 'Reordering invalidated references' unless drawings.section_references(targets) == drawings.section_references(targets.reverse)
raise 'Legacy plans must regenerate to draw the line' unless JSON.parse(drawings.section_references(targets)).first == 'cut-line-v1'
raise 'A plan without sections should stay valid' unless drawings.section_references([]) == '[]'
references = drawings.section_references(targets)
attributes = { 'section_references' => references }
plan_page = Object.new
plan_page.define_singleton_method(:get_attribute) { |_dict, key| attributes[key] }
raise 'Old plans need regeneration for wall projections' unless drawings.plan_needs_update?(plan_page, references)
attributes['plan_projected_walls'] = []
raise 'Old plans need regeneration for grid bubbles' unless drawings.plan_needs_update?(plan_page, references)
attributes['plan_grid_bubbles'] = 0
raise 'A regenerated plan may have no projected walls' if drawings.plan_needs_update?(plan_page, references)

datums = Higeotoko::SbrArchitecture::DrawingDatums
[50, 100].each do |scale|
  spans = datums.section_line_spans(-20 * scale, 42 * scale, scale)
  raise 'Solid ends must meet the arrows' unless spans.first == [-20 * scale, -16 * scale] && spans.last == [38 * scale, 42 * scale]
  raise 'Expected a long and two short strokes' unless spans[1, 3].zip([8, 1.2, 1.2]).all? { |(a, b), mm| ((b - a) / scale - mm).abs < 0.001 }
  raise 'Strokes should have gaps' unless spans.each_cons(2).all? { |(_, a), (b, _)| b - a >= 1.49 * scale }
end
raise 'A short mark should stay connected' unless datums.section_line_spans(0, 300, 50) == [[0, 300]]
cuts = Higeotoko::SbrArchitecture::ColumnCuts
diagonal = datums.dimension_mask([0, 0], [4000, 4000], 140)
raise 'A diagonal dimension masked unrelated reference frames' if cuts.intersects?([900, 3000], [1500, 3000], [diagonal])
raise 'The area around a diagonal dimension was lost' unless cuts.intersects?([1900, 2000], [2100, 2000], [diagonal])
horizontal = datums.dimension_mask([1000, 500], [2500, 500], 140)
raise 'The mask for a horizontal dimension changed' unless horizontal.drop(1) == [[860, 2640], [360, 640]]
puts 'Sheet numbering and section reference checks passed'
