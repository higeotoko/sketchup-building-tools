# frozen_string_literal: true

require 'tmpdir'
require_relative '../extension/sbr_architecture/drawing_schedules'
require_relative '../extension/sbr_architecture/layout_sheets'
require_relative '../extension/sbr_architecture/layout_schedule_update'

class Numeric
  def to_mm = self
end

module Layout
  class Attributes
    def set_attribute(dict, key, value) = ((@attributes ||= {})[[dict, key]] = value)
    def get_attribute(dict, key) = @attributes&.fetch([dict, key], nil)
  end

  class Layer
    attr_reader :name

    def initialize(name) = (@name = name)
    def locked? = false
  end

  class LayerInstance
    attr_reader :definition, :entities

    def initialize(definition, page)
      @definition = definition
      @entities = page.nonshared_entities
    end

    def entity_index(entity) = entities.index(entity)
    def reorder_entity(entity, index) = entities.insert(index, entities.delete_at(entity_index(entity)))
  end

  class Entity < Attributes
    attr_accessor :layer_instance, :locked

    def locked? = @locked
  end

  class Table < Entity
    def initialize(columns, rows)
      @columns = columns
      @rows = rows
    end

    def dimensions = [@rows, @columns.size]
    def [](_row, column) = Struct.new(:data).new(FormattedText.new(@columns.fetch(column)))
  end

  class FormattedText < Entity
    attr_reader :plain_text

    def initialize(text) = (@plain_text = text)
  end

  class Page < Attributes
    attr_reader :name, :nonshared_entities

    def initialize(name)
      @name = name
      @nonshared_entities = []
    end
  end

  class Document < Attributes
    attr_reader :pages, :layers

    def initialize
      @pages = []
      @layers = []
    end

    def self.open(_source) = @fixture
    def self.fixture=(doc)
      @fixture = doc
    end

    def page_info = Struct.new(:width, :height).new(420, 297)
    def add_entity(entity, layer, page)
      entity.layer_instance = LayerInstance.new(layer, page)
      page.nonshared_entities << entity
      entity
    end

    def remove_entity(entity) = entity.layer_instance.entities.delete(entity)
    def save(destination) = File.write(destination, 'new layout')
  end
end

api = Higeotoko::SbrArchitecture
update = api::LayoutScheduleUpdate
sheets = api::LayoutSheets

module Higeotoko::SbrArchitecture::LayoutSheets
  def self.check_rooms!(_model); end

  def self.schedule_body(sheet)
    _, _, note, headings, _, rows = sheet
    { 'summary' => ::Layout::FormattedText.new(note), 'table' => ::Layout::Table.new(headings, rows.size + 1) }.each do |role, entity|
      entity.set_attribute(SCHEDULE_META, 'role', role)
    end
  end

  def self.schedule_sheet(doc, layer, sheet)
    number, title = sheet
    page = ::Layout::Page.new(title)
    doc.pages << page
    page.set_attribute(SCHEDULE_META, 'sheet', number)
    schedule_body(sheet).each_value { |entity| doc.add_entity(entity, layer, page) }
    page
  end
end

module Higeotoko::SbrArchitecture::DrawingSchedules
  def self.pages(model, _types) = model.current_sheets
end

def expect_error(message)
  yield
  raise "Expected #{message}"
rescue ArgumentError => e
  raise unless e.message.include?(message)
end

Dir.mktmpdir do |folder|
  model_path = File.join(folder, 'sample.skp')
  source = File.join(folder, 'sample.layout')
  output = File.join(folder, 'updated.layout')
  File.write(model_path, 'model')
  File.write(source, 'original layout')
  doc = Layout::Document.new
  layer = Layout::Layer.new(sheets::SCHEDULE_LAYER)
  doc.layers << layer
  plan = Layout::Page.new('平面 1FL')
  doc.pages << plan
  viewport = doc.add_entity(Layout::Entity.new, layer, plan)
  _, _, headings, widths = api::DrawingSchedules::TABLES.fetch('rooms')
  rows = api::DrawingSchedules.paginate([['1FL', '室名', '24.00', '']], widths).first
  first = ['T-02', '室一覧', '室 1件　　面積集計 24.00 m²', headings, widths, rows]
  continuation = ['T-02-02', '室一覧（2）', first[2], headings, widths, rows]
  model = Struct.new(:path, :current_sheets, :modified?).new(model_path, [first], false)

  legacy = Layout::Page.new('室一覧')
  doc.pages << legacy
  heading = doc.add_entity(Layout::FormattedText.new('T-02    室一覧'), layer, legacy)
  old_table = doc.add_entity(Layout::Table.new(headings, 2), layer, legacy)
  note = doc.add_entity(Layout::FormattedText.new('この注記を残す'), layer, legacy)
  doc.add_entity(Layout::FormattedText.new('室 5件　　面積集計 17.00 m²'), layer, legacy)
  tail = sheets.schedule_sheet(doc, layer, continuation)
  tail_note = doc.add_entity(Layout::FormattedText.new('続きページの手書き追記'), layer, tail)
  Layout::Document.fixture = doc

  expect_error('新しいファイル名') { update.save_copy(model, source, source) }
  Dir.mktmpdir { |other| expect_error('同じフォルダ') { update.save_copy(model, source, File.join(other, 'copy.layout')) } }
  result = update.save_copy(model, source, output)
  raise 'A legacy copy modified its input' unless File.read(source) == 'original layout' && File.read(output) == 'new layout'
  raise 'Unexpected legacy migration result' unless result == { updated: 1, added: 0, retired: 1, legacy: true }
  raise 'Plan or page order changed' unless doc.pages == [plan, legacy, tail] && plan.nonshared_entities == [viewport]
  raise 'Handwritten text moved in the layer' unless legacy.nonshared_entities[0] == heading && legacy.nonshared_entities[2] == note
  raise 'Table contents were not replaced' if legacy.nonshared_entities.include?(old_table)
  raise 'Continuation notes were removed' unless tail.nonshared_entities.include?(tail_note)
  raise 'Retired page stayed stale' unless tail.nonshared_entities.grep(Layout::FormattedText).first.plain_text.include?('続く行はありません')

  model.current_sheets = [first, continuation, continuation.dup.tap { |item| item[0] = 'T-02-03'; item[1] = '室一覧（3）' }]
  result = update.update_document(doc, model)
  raise 'A continuation was duplicated or lost' unless result == { updated: 2, added: 1, retired: 0, legacy: false }
  raise 'Continuation page was replaced' unless doc.pages[2] == tail && tail.nonshared_entities.include?(tail_note)
  raise 'Repeating an update appended more pages' unless update.update_document(doc, model)[:added].zero? && doc.pages.size == 4
  legacy.nonshared_entities.grep(Layout::Table).first.locked = true
  expect_error('ロック') { update.update_document(doc, model) }
  expect_error('元のSKP') { update.update_document(doc, Struct.new(:path).new(source)) }
end
puts 'LayOut schedule refresh keeps source files, page identity, draw order and manual notes'
