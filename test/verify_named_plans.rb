# frozen_string_literal: true

PAGE_USE_CAMERA = 1
PAGE_USE_SECTION_PLANES = 2
PAGE_USE_LAYER_VISIBILITY = 4
PAGE_USE_HIDDEN_OBJECTS = 8
PAGE_USE_RENDERING_OPTIONS = 16

require_relative '../extension/sbr_architecture/layout'
require_relative '../extension/sbr_architecture/layout_sheets'
require_relative '../extension/sbr_architecture/drawings'
require_relative '../extension/sbr_architecture/publication_sets'

module Higeotoko::SbrArchitecture
  def self.levels(_model) = { '1FL' => 450, '2FL' => 3450 }
end

Page = Struct.new(:data, :number) do
  def get_attribute(_dict, key)
    return JSON.generate(data) if key == 'spec'
    return number if key == 'sheet_number'
  end
end
Model = Struct.new(:pages) do
  def get_attribute(_dict, _key, default = nil) = default
end

api = Higeotoko::SbrArchitecture
drawings = api::Drawings
model = Model.new([])
standard = { 'kind' => 'plan', 'level' => '1FL', 'cut' => 1100, 'scale' => 50 }
base = drawings.spec(model, standard)
raise 'Existing plan key or title changed' unless base['key'] == 'plan:1FL' && drawings.title(base) == '平面 1FL'
model.pages << Page.new(base, 1)
first = drawings.spec(model, standard.merge('plan_name' => ' 建具確認 ', 'cut' => 1350, 'scale' => 100,
                                            'opening_dimensions' => true, 'plan_bottom' => '-300', 'plan_top' => '3000',
                                            'plan_crop' => [3900, 3500, 900, 1300]))
raise 'Named plan reused the standard view' unless first['key'].start_with?('plan-view:') && first['plan_name'] == '建具確認'
model.pages << Page.new(first, 9)
second = drawings.spec(model, standard.merge('plan_name' => '仕上確認', 'cut' => 1250, 'hatch' => true))
raise 'Named views share the same key' if second['key'] == first['key']
model.pages << Page.new(second, 10)
raise 'Saved named view did not round-trip' unless drawings.spec(model, first) == first
raise 'Named plan ranges were not saved in millimetres' unless first.values_at('plan_bottom', 'plan_top') == [-300, 3000]
raise 'Crop did not normalize reversed corners' unless first['plan_crop'] == [900, 1300, 3900, 3500]
raise 'Crop extent is wrong' unless api::PlanCrop.extent(first['plan_crop']) == [3000, 2200]
raise 'Crop leaked into other views' if base.key?('plan_crop') || second.key?('plan_crop')
uncropped = drawings.spec(model, first.merge('plan_crop' => nil))
raise 'Removing crop changed the view identity' unless uncropped['key'] == first['key'] && !uncropped.key?('plan_crop')
[
  [base, [0, 0, 3000, 2200]],
  [first, [0, 0, 0, 2200]],
  [first, ['a', 0, 3000, 2200]],
  [first, [0, 0]],
  [first, [0, 0, Float::INFINITY, 2200]]
].each do |plan, crop|
  begin
    drawings.spec(model, plan.merge('plan_crop' => crop))
  rescue ArgumentError
    next
  end
  raise 'An invalid crop was saved'
end
raise 'Another view inherited the range' if [base, second].any? { |view| view.key?('plan_bottom') || view.key?('plan_top') }
cleared = drawings.spec(model, first.merge('plan_bottom' => '', 'plan_top' => ''))
raise 'Clearing the range did not restore defaults' if cleared.key?('plan_bottom') || cleared.key?('plan_top')
raise 'The standard view was changed' unless drawings.spec(model, base) == base
raise 'Title does not identify floor and view' unless drawings.title(first) == '平面 1FL｜建具確認'

edited = drawings.spec(model, first.merge('plan_name' => '建具納まり', 'cut' => 1400, 'scale' => 25))
raise 'Renaming or rescaling a named view replaced its key' unless edited['key'] == first['key']
raise 'Another plan was affected' unless second.values_at('cut', 'scale') == [1250, 50] && base['cut'] == 1100
raise 'Existing drawing numbers were reassigned' unless
  drawings.assign_sheet_numbers(model, drawings.specs(model), [edited['key'], second['key'], base['key']]).values_at(edited['key'], second['key'], base['key']) == [9, 10, 1]
selected = api::PublicationSets.drawing_subset(drawings.specs(model), [first['key']])
raise 'Publication expanded the selected view to its entire floor' unless selected.map(&:last) == [first]

begin
  drawings.spec(model, standard.merge('plan_name' => '建具確認'))
  raise 'A duplicate name on the same floor was accepted'
rescue ArgumentError => e
  raise unless e.message.include?('使用済み')
end
other_floor = drawings.spec(model, standard.merge('level' => '2FL', 'plan_name' => '建具確認'))
raise 'The same name on another floor did not produce a new view' if other_floor['key'] == first['key']
begin
  drawings.spec(model, first.merge('level' => '2FL'))
  raise 'An edit with the wrong floor was accepted'
rescue ArgumentError => e
  raise unless e.message.include?('この階')
end
puts 'Named plans preserve legacy keys, independent view ranges and crops, scales, numbers and publication selection'
