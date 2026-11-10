# frozen_string_literal: true

require 'json'
require_relative '../extension/sbr_architecture/layout'
require_relative '../extension/sbr_architecture/openings'
require_relative '../extension/sbr_architecture/plan_opening_pick'
require_relative '../extension/sbr_architecture/grid_style'
require_relative '../extension/sbr_architecture/work_view'
require_relative '../extension/sbr_architecture/elevation_datums'

PAGE_USE_CAMERA = 1
PAGE_USE_SECTION_PLANES = 2
PAGE_USE_LAYER_VISIBILITY = 4
PAGE_USE_HIDDEN_OBJECTS = 8
PAGE_USE_RENDERING_OPTIONS = 16
require_relative '../extension/sbr_architecture/drawings'

class Numeric
  def to_mm
    self * 25.4
  end
end

module Sketchup
  SectionPlane = Struct.new(:get_plane)
  Color = Struct.new(:red, :green, :blue)
  class Pages
    def self.add_frame_change_observer(_observer) = 1
    def self.remove_frame_change_observer(_id) = true
  end
end

api = Higeotoko::SbrArchitecture
raise 'Continuous grid or missing dots' unless api::GridStyle.pattern_spans(1500) ==
                                              [[0, 410], [510, 560], [660, 1070], [1170, 1220], [1320, 1500]]
raise 'Small final segment is malformed' unless api::GridStyle.pattern_spans(411) == [[0, 410]]

native = Sketchup::SectionPlane.new([-1, 0, 0, 1234 / 25.4])
active = Sketchup::SectionPlane.new([0, 1, 0, -800 / 25.4])
entities = Struct.new(:active_section_plane, :items) do
  def include?(plane)
    items.include?(plane)
  end
end.new(active, [native, active])
model = Struct.new(:entities, :selection).new(entities, [native])
def model.get_attribute(_dictionary, _key, default) = default
raise 'Selected SketchUp section was not preferred' unless api::Drawings.native_section_input(model) == { side: 'x+', offset: 1234.0 }
model.selection.clear
raise 'Reverse cut direction was lost' unless api::Drawings.native_section_input(model) == { side: 'y-', offset: 800.0 }
entities.active_section_plane = Sketchup::SectionPlane.new([0, 0, 1, 0])
begin
  api::Drawings.native_section_input(model)
  raise 'A horizontal cut was treated as a vertical drawing'
rescue ArgumentError => e
  raise unless e.message.include?('縦断面')
end

picker = api::Openings::PlanPick.allocate
door = { 'kind' => 'door', 'offset' => 1800, 'width' => 900, 'sill' => 0, 'height' => 2000, 'segment' => 1, 'id' => 'door' }
segment = api::Openings::PlanPick::Segment.new(nil, { 'openings' => [door] }, 1, nil, nil, nil, nil, 1100)
hit = api::Openings::PlanPick::Hit.new(segment, 1800, door)
raise 'Click missed the opening' unless picker.opening_at(segment, 1800, 1100) == door
raise 'Opening was picked outside its jambs' if picker.opening_at(segment, 2300, 1100)
raise 'Opening was picked above its head' if picker.opening_at(segment, 1800, 2100)
quadrants = [[-1, 1], [-1, -1], [1, 1], [1, -1]]
directions = quadrants.map { |along, across| api::Openings.direction_at(along, across) }
raise 'One or more hinge/opening sides were reversed' unless directions == %w[start_left start_right end_left end_right]
raise 'An ambiguous click on the centreline chose a swing' if api::Openings.direction_at(200, 0)
window = door.merge('kind' => 'window', 'sill' => 900, 'swing' => 'end_right')
raise 'Legacy window kept its door swing' if api::Openings.swing_path(window, 60, -60)
outline = [[0, 0], [4000, 0], [4000, 3000], [0, 3000], [0, 0]]
values = { 'width' => 900, 'height' => 1100, 'sill' => 900, 'mount_offset' => '30', 'mount_mode' => 'outset' }
api::Openings::WINDOW_TYPES.each_key do |type|
  opening = window.merge(api::Openings.parameters('window', values.merge('window_type' => type)))
  raise 'A window used a door swing' if api::Openings.swing_path(opening, 60, -60)
  paths = api::Openings.window_paths(opening, 60, -60, outline)
  raise 'Outset did not move the window outside' unless paths.first.first.last == -90
  count = { 'single_slide' => 8, 'double_casement' => 3, 'sliding' => 6, 'vertical_awning' => 2, 'casement' => 2, 'double_hung' => 2 }
  raise 'Wrong number of symbol strokes' unless paths.size == count.fetch(type, 1)
  if type == 'vertical_awning'
    raise 'Casement indicator did not face outside' unless paths.last.last.last < -90
  end
  raise 'Reversed wall reversed the exterior' unless api::Openings.window_anchor(opening, 60, -60, outline.reverse) == [90, 1]
end
first, second = api::Sashes.sliding_parts(1650, 1100)
raise 'Sliding sashes did not meet near the centre' unless first[0].last > second[0].first
raise 'Sliding sashes were drawn on the same track' unless first[1].last < second[1].first
inset = window.merge(api::Openings.parameters('window', values.merge('mount_mode' => 'inset')))
raise 'Inset did not move the window inward' unless api::Openings.window_anchor(inset, 60, -60, outline) == [-30, -1]
begin
  picker.validate_opening!(hit, door.merge('sill' => 1200))
  raise 'Opening not intersected by the plan was allowed'
rescue ArgumentError => e
  raise unless e.message.include?('切断高さ')
end

def api.levels(_model)
  { 'GL' => 0, '1FL' => 450, '2FL' => 3200 }
end

drawings = api::Drawings
def drawings.specs(_model)
  [[nil, { 'key' => 'plan:1FL' }], [nil, { 'key' => 'elevation:x+' }]]
end

def drawings.generate(model, inputs, within_operation:, provisional:)
  raise 'Grid scenes did not share the placement operation' unless within_operation
  raise 'Grid scenes were not marked provisional' unless provisional

  inputs.map { |item| spec(model, item).fetch('key') }
end

seeds = drawings.seed_from_grid(model)
raise 'Seeding duplicated an existing scene or missed a level' unless seeds == %w[plan:2FL elevation:x- elevation:y+ elevation:y-]
raise 'North was interpreted as the viewing direction' unless drawings::CLOCKWISE.map { |side| drawings.compass('x+', side) } == %w[西 北 東 南]
raise 'Unconfigured projects need their original axis labels' unless drawings.title(drawings.spec(model, { 'kind' => 'elevation', 'side' => 'x+' })) == '立面 ＋X側'
datums = api::ElevationDatums
rear = datums::Band.new(nil, 0, [[0, 0], [1000, 0], [1000, 120], [0, 120]], 0, 2400, true)
front = datums::Band.new(nil, 1, [[300, 500], [700, 500], [700, 620], [300, 620]], 0, 1800, true)
raise 'A rear opening was annotated through a front wall' if datums.visible?([front, rear], rear, 500, 120, 1000)
raise 'A visible opening was removed' unless datums.visible?([front, rear], rear, 100, 120, 1000) &&
                                             datums.visible?([front, rear], rear, 500, 120, 2000)
combined = datums.labels([['W-02', '上端', 2100], ['W-01', '上端', 2100]], { 'ridge' => 4200 })
raise 'Equal heights did not group or the roof mark was lost' unless combined == [['W-01 ほか1件 上端', 2100], ['棟高', 4200]]

style_set = Class.new(Array) { attr_accessor :selected_style }.new
view = Object.new
def view.invalidate = nil
working = Struct.new(:rendering_options, :styles, :active_view).new(
  { 'BackgroundColor' => Sketchup::Color.new(201, 202, 203), 'ForegroundColor' => Sketchup::Color.new(4, 5, 6),
    'DrawGround' => true }, style_set, view
)
work_view = api::WorkView
raise 'Dark view did not turn on' unless work_view.toggle(working)
raise 'Dark view retained the ground' if working.rendering_options['DrawGround']
raise 'Dark view did not change the background' unless working.rendering_options['BackgroundColor'].red == 30
work_view.without_override(working) do
  raise 'Work-view override leaked to style storage' unless working.rendering_options['BackgroundColor'].red == 201

  drawings.drawing_style(working, 'plan', false)
  raise 'Paper scene inherited the dark background or light foreground' unless
    working.rendering_options.values_at('BackgroundColor', 'ForegroundColor').map(&:red) == [255, 24]
end
raise 'Work view did not return to dark' unless working.rendering_options['BackgroundColor'].red == 30
raise 'Dark view did not turn off' if work_view.toggle(working)
raise 'Paper settings were not restored' unless working.rendering_options.values_at('BackgroundColor', 'ForegroundColor').map(&:red) == [255, 24]
puts 'Plan opening, native section, physical grid and screen/paper colours passed'
