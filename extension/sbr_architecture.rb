# frozen_string_literal: true

require 'sketchup.rb'
require 'extensions.rb'

module Higeotoko
  module SbrArchitecture
    unless file_loaded?(__FILE__)
      extension = SketchupExtension.new('SketchUPbuildingTool', 'sbr_architecture/main')
      extension.description = '建築パレットで壁・床・柱梁・基礎・通り芯を作図し、図面・建具表・数量・IFC4を出力します。'
      extension.version = '1.32.0'
      extension.creator = 'Higeotoko'
      Sketchup.register_extension(extension, true)
      file_loaded(__FILE__)
    end
  end
end
