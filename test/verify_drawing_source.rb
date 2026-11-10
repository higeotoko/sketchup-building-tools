# frozen_string_literal: true

PAGE_USE_CAMERA = 1
PAGE_USE_SECTION_PLANES = 2
PAGE_USE_LAYER_VISIBILITY = 4
PAGE_USE_HIDDEN_OBJECTS = 8
PAGE_USE_RENDERING_OPTIONS = 16

require_relative '../extension/sbr_architecture/drawings'

module Sketchup
  class Drawingelement
    attr_accessor :persistent_id, :layer, :transformation, :definition, :vertices, :kind, :parameters, :hidden

    def get_attribute(_dictionary, _key) = parameters
  end

  class Group < Drawingelement; end
  class ComponentInstance < Drawingelement; end
  class Edge < Drawingelement; end
  class Face < Drawingelement; end
  class Image < Drawingelement; end
end

module Higeotoko::SbrArchitecture
  DICT = 'test'
  def self.levels(model) = model.levels

  module Follow
    def self.kind(entity) = entity.kind
  end
end

layer = Struct.new(:name, :key) { def get_attribute(_dictionary, _key) = key }
ordinary = layer.new('Untagged', nil)
wall = Sketchup::Group.new
wall.persistent_id, wall.layer, wall.kind, wall.parameters = 7, ordinary, 'wall', '{"width":120}'
wall.transformation = [0, 0, 0]
generated = Sketchup::Group.new
generated.persistent_id, generated.layer = 8, layer.new('図面注記', 'plan:1FL')
component = Sketchup::ComponentInstance.new
component.persistent_id, component.layer, component.transformation = 9, ordinary, [0, 0, 0]
component.definition = Struct.new(:guid).new('guid-1')
model = Struct.new(:entities, :levels, :options).new([wall, generated, component], { '1FL' => 450 },
                                                  { 'UnitsOptions' => { 'LengthUnit' => 2, 'LengthFormat' => 0 } })
drawings = Higeotoko::SbrArchitecture::Drawings
saved = drawings.source_signature(model)
wall.hidden = true
generated.transformation = [0, 0, 100]
model.entities.reverse!
raise 'Viewing state or generated drawing changed the fingerprint' unless drawings.source_signature(model) == saved
wall.parameters = '{"width":150}'
raise 'A saved wall edit was not detected' if drawings.source_signature(model) == saved
wall.parameters = '{"width":120}'
wall.transformation[0] = 12
raise 'A moved wall was not detected' if drawings.source_signature(model) == saved
wall.transformation[0] = 0
component.definition.guid = 'guid-2'
raise 'A native component edit was not detected' if drawings.source_signature(model) == saved
puts 'Drawing source signatures detect registered changes without depending on the active scene'
