# frozen_string_literal: true

module Higeotoko
  module SbrArchitecture
    module WorkView
      COLORS = {
        'BackgroundColor' => [30, 32, 36],
        'ForegroundColor' => [219, 224, 231],
        'SectionDefaultCutColor' => [212, 219, 229]
      }.freeze
      BACKDROP = %w[DisplaySky DisplayGround DrawGround DrawHorizon DisplayFog].freeze
      module_function

      class SceneObserver
        def frameChange(_from, to, progress)
          return unless to && progress >= 1.0 && WorkView.enabled?(to.model)

          model = to.model
          UI.start_timer(0, false) { WorkView.apply(model) if Sketchup.active_model == model && WorkView.enabled?(model) }
        end
      end

      def enabled?(model)
        !!@model && @model == model
      end

      def toggle(model)
        if enabled?(model)
          restore(model)
          @model = @original = nil
          Sketchup::Pages.remove_frame_change_observer(@observer)
          @observer = nil
          return false
        end

        restore(@model) if @model&.valid?
        @model = model
        @original = {}
        @observer ||= Sketchup::Pages.add_frame_change_observer(SceneObserver.new)
        apply(model)
        true
      end

      def options
        @options ||= COLORS.transform_values { |rgb| Sketchup::Color.new(*rgb) }
                           .merge(BACKDROP.to_h { |key| [key, false] })
      end

      def apply(model)
        return unless enabled?(model)

        rendering = model.rendering_options
        keys = rendering.keys
        options.each do |key, dark|
          next unless keys.include?(key)

          current = rendering[key]
          next if current == dark

          @original[key] = current
          rendering[key] = dark
        end
        model.active_view.invalidate
      end

      def restore(model)
        rendering = model.rendering_options
        @original.each do |key, original|
          rendering[key] = original if rendering[key] == options[key]
        end
        @original.clear
        model.active_view.invalidate
      end

      def without_override(model)
        active = enabled?(model)
        restore(model) if active
        yield
      ensure
        apply(model) if active
      end
    end
  end
end
