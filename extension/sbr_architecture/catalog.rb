# frozen_string_literal: true

require_relative 'steel_engine/core'
require_relative 'steel_engine/builder'

module Higeotoko
  module SbrArchitecture
    module Catalog
      STEEL = SbrArchitectureBundled::Steel
      SYSTEMS = { 'timber' => '木造', 'steel' => '鉄骨造', 'rc' => 'RC造' }.freeze
      TIMBER_ROLES = {
        'column' => %w[column through_column],
        'beam' => %w[floor_beam rim_beam eave_beam roof_beam]
      }.freeze
      module_function

      def timber_roles(kind)
        @roles ||= load_timber('roles')
        TIMBER_ROLES.fetch(kind).to_h { |id| [id, @roles.fetch(id)] }
      end

      def timber_sections(role)
        @sections ||= load_timber('sections')
        role.fetch('sections').to_h { |id| [id, @sections.fetch(id)] }
      end

      def load_timber(file)
        JSON.parse(File.read(File.join(__dir__, 'timber_data', "#{file}.json"), encoding: 'UTF-8')).fetch('entries')
      end

      def steel
        @steel ||= STEEL::Library.new(Dir[File.join(__dir__, 'steel_engine/data/*.json')].sort)
      end

      def steel_default(kind)
        preferred = kind == 'column' ? 'BOX' : 'H'
        width = kind == 'column' ? 300 : 150
        options = steel.options.select { |entry| entry[2] == preferred }
        option = options.find { |entry| entry.last(2) == [300, width] } || options.first
        steel.fetch(option.first)
      end

      def steel_options
        @steel_options ||= steel.options.map { |entry| entry.first(3).freeze }.freeze
      end

      def steel_params(section, kind, height = nil)
        params = {
          'system' => 'steel', 'section_id' => section.id,
          'width' => section.dimensions.fetch('B'), 'depth' => section.dimensions.fetch('H')
        }
        params['height'] = Layout.mm(height, '柱高さ', positive: true) if kind == 'column'
        params
      end

      def timber_params(kind, role_id, section_id, height = nil)
        role = timber_roles(kind).fetch(role_id)
        section = timber_sections(role).fetch(section_id)
        params = {
          'system' => 'timber', 'role' => role_id, 'section_id' => section_id,
          'width' => section.fetch('width'), 'depth' => section.fetch('depth')
        }
        params['height'] = Layout.mm(height, '柱高さ', positive: true) if kind == 'column'
        params
      end
    end
  end
end
