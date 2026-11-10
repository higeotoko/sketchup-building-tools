# frozen_string_literal: true

require 'tmpdir'
require_relative '../extension/sbr_architecture/drawing_schedules'
require_relative '../extension/sbr_architecture/layout_sheets'
require_relative '../extension/sbr_architecture/publication_sets'

module Layout
  Document = Class.new
end

module Higeotoko::SbrArchitecture
  def self.operation(_model, _name) = yield

  module Drawings
    META = 'test'
    module_function

    def specs(model) = model.scenes
    def source_signature(model) = model.data.fetch('source_signature', 'current')
    def sheet_label(number) = format('A-%02d', number)
    def title(data) = data.fetch('key')
    def section_targets(data, numbers)
      data.filter_map { |item| numbers.fetch(item.fetch('key')) if item['kind'] == 'section' }
    end
    def section_references(sections) = sections.sort
    def plan_needs_update?(page, references) = page.attributes['references'] != references
  end

  module Rooms
    def self.items(model) = model.data.fetch('rooms', [])
  end
end

Model = Struct.new(:path, :scenes, :data, :modified?) do
  def get_attribute(_dict, key, default = nil) = data.fetch(key, default)
  def set_attribute(_dict, key, value) = data[key] = value
end
Scene = Struct.new(:name, :attributes) do
  def get_attribute(_dict, key, default = nil) = attributes.fetch(key, default)
end

api = Higeotoko::SbrArchitecture
sets = api::PublicationSets
layout = api::LayoutSheets
def expect_error(message)
  yield
  raise "Expected #{message}"
rescue ArgumentError => e
  raise unless e.message.include?(message)
end

Dir.mktmpdir do |folder|
  path = File.join(folder, 'test.skp')
  File.write(path, 'saved')
  base = { 'paper_scale' => 50, 'extent_mm' => [7500, 6200], 'source_signature' => 'current' }
  plan = [Scene.new('平面 1FL', base.merge('sheet_number' => 1, 'references' => [7], 'drawn_section_keys' => ['section:a-a'])),
          { 'key' => 'plan:1FL', 'kind' => 'plan' }]
  draft = [Scene.new('梁伏図 2FL', base.merge('sheet_number' => 4, 'stats' => '{"provisional":true}')),
           { 'key' => 'framing:2FL', 'kind' => 'framing' }]
  section = [Scene.new('断面 A-A', base.merge('sheet_number' => 7)), { 'key' => 'section:a-a', 'kind' => 'section' }]
  model = Model.new(path, [plan, draft, section], {}, false)
  expect_error('仮の図面') { layout.check_source!(model) }
  expect_error('1枚以上') { sets.save(model, { 'name' => '空', 'keys' => [] }) }

  item = sets.save(model, { 'name' => '  確認用  ', 'keys' => %w[section:a-a plan:1FL], 'tables' => ['openings'],
                           'arrangement' => 'grouped' })
  id = item.fetch('id')
  raise 'Set order should follow the model and trim name' unless item.values_at('name', 'keys') == ['確認用', %w[plan:1FL section:a-a]]
  expect_error('同じ名前') { sets.save(model, { 'name' => '確認用', 'keys' => ['plan:1FL'] }) }
  expect_error('表の設定') { sets.save(model, { 'name' => '別のセット', 'keys' => ['plan:1FL'], 'tables' => ['unknown'] }) }
  expect_error('配置方法') { sets.save(model, { 'name' => '別のセット', 'keys' => ['plan:1FL'], 'arrangement' => 'unknown' }) }
  raise 'Unselected drafts blocked a complete set' unless layout.check_source!(model, keys: item['keys']) == [plan, section]
  expect_error('A-07') { layout.check_source!(model, keys: ['plan:1FL']) }
  raise 'An explicit reference exception was rejected' unless layout.check_source!(model, keys: ['plan:1FL'], allow_missing_sections: true) == [plan]
  model.data['source_signature'] = 'changed and saved'
  expect_error('更新が必要な図面') { layout.check_source!(model, keys: item['keys']) }
  model.data.delete('source_signature')
  model.data['rooms'] = [Object.new]
  expect_error('室一覧の面積') { layout.check_source!(model, keys: item['keys'], tables: ['rooms']) }
  model.data['room_schedule_signature'] = 'current'
  raise 'Refreshed room schedules did not pass' unless layout.check_source!(model, keys: item['keys'], tables: ['rooms']) == [plan, section]

  section.first.name = '断面 A-A 改訂'
  clone = Model.new(path, model.scenes, JSON.parse(JSON.generate(model.data)), false)
  raise 'Set did not survive save or scene rename' unless sets.find(clone, id) == item
  renamed = sets.save(model, item.merge('name' => '提出用'))
  raise 'Rename created a new set' unless renamed['id'] == id && sets.all(model).size == 1
  model.scenes.delete(section)
  expect_error('削除済みの図面') { layout.check_source!(model, keys: renamed['keys']) }
  plan.first.attributes['references'] = []
  plan.first.attributes['drawn_section_keys'] = []
  repaired = sets.save(model, renamed.merge('keys' => ['plan:1FL']))
  raise 'Repair did not keep the set ID' unless repaired['id'] == id && layout.check_source!(model, keys: repaired['keys']) == [plan]
  sets.remove(model, id)
  expect_error('見つかりません') { sets.find(model, id) }
  raise 'Removed set remained' unless sets.all(model).empty?
end
puts 'Publication sets persist, preserve scene keys and scope validation to chosen drawings'
