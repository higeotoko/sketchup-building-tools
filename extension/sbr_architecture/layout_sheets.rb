# frozen_string_literal: true

module Higeotoko
  module SbrArchitecture
    module LayoutSheets
      module_function

      def check_source!(model)
        raise ArgumentError, 'このSketchUp環境ではLayOutへの配置を利用できません。' unless defined?(::Layout::Document)
        raise ArgumentError, '先に図面シーンを作成してください。' if Drawings.specs(model).empty?
        if model.path.empty? || model.modified? || !File.file?(model.path)
          raise ArgumentError, '図面シーンを更新したSKPを保存してから配置してください。'
        end
      end

      def sheet_bounds(x, y, width, height)
        Geom::Bounds2d.new(x.mm.to_f, y.mm.to_f, width.mm.to_f, height.mm.to_f)
      end

      def export(model, file)
        check_source!(model)
        file = "#{file}.layout" unless File.extname(file).casecmp?('.layout')
        if File.exist?(file)
          raise ArgumentError, '新しいファイル名で保存してください。作成済みの図面はLayOutの参照更新で更新できます。'
        end

        doc = ::Layout::Document.new
        doc.page_info.width = 420.mm.to_f
        doc.page_info.height = 297.mm.to_f
        layer = doc.layers[0]
        scene_indices = model.pages.to_a.each_with_index.to_h { |page, index| [page.persistent_id, index + 1] }
        scenes = Drawings.specs(model)
        scenes.each_with_index do |(scene, spec), i|
          title = Drawings.title(spec)
          page = i.zero? ? doc.pages[0] : doc.pages.add(title)
          page.name = title
          viewport = ::Layout::SketchUpModel.new(model.path, sheet_bounds(14, 30, 392, 252))
          viewport.current_scene = scene_indices.fetch(scene.persistent_id)
          viewport.render_mode = ::Layout::SketchUpModel::HYBRID_RENDER
          doc.add_entity(viewport, layer, page)
          viewport.render if viewport.render_needed?
          heading = ::Layout::FormattedText.new("#{format('%02d', i + 1)}   #{title}", sheet_bounds(14, 12, 392, 14))
          doc.add_entity(heading, layer, page)
        end
        doc.save(file)
        raise ArgumentError, 'LayOutファイルを保存できませんでした。' unless File.file?(file)

        scenes.size
      end
    end
  end
end
