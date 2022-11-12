# frozen_string_literal: true

module TemporalTables
  module TemporalAdapter # rubocop:disable Metrics/ModuleLength
    def create_table(table_name, **options, &block) # rubocop:disable Metrics/MethodLength, Metrics/AbcSize, Metrics/PerceivedComplexity, Metrics/CyclomaticComplexity
      if options[:temporal_bypass]
        super(table_name, **options, &block)
      else
        skip_table = TemporalTables.skipped_temporal_tables.include?(table_name.to_sym) || table_name.to_s =~ /_h$/

        super(table_name, **options) do |t|
          block.call t

          if TemporalTables.add_updated_by_field && !skip_table
            updated_by_already_exists = t.columns.any? { |c| c.name == 'updated_by' }
            if updated_by_already_exists
              puts "consider adding #{table_name} to TemporalTables skip_table" # rubocop:disable Rails/Output
            else
              t.column(:updated_by, TemporalTables.updated_by_type)
            end
          end
        end

        if options[:temporal] || (TemporalTables.create_by_default && !skip_table)
          add_temporal_table table_name, **options
        end
      end
    end

    def add_temporal_table(table_name, **options) # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
      create_table(
        temporal_name(table_name),
        **options.merge(id: false, primary_key: 'history_id', temporal_bypass: true)
      ) do |t|
        t.column :id, options.fetch(:id, :integer) if options[:id] != false
        t.datetime :eff_from, null: false, limit: 6
        t.datetime :eff_to,   null: false, limit: 6, default: '9999-12-31'

        columns(table_name).each do |c|
          next if c.name == 'id'

          if t.respond_to?(c.type)
            column_options = { limit: c.limit }
            column_options[:enum_type] = c.sql_type_metadata.sql_type if c.type == :enum
            t.send c.type, c.name, **column_options
          else          
            t.column c.name, c.sql_type_metadata.sql_type
          end
        end
      end

      if TemporalTables.add_updated_by_field && !column_exists?(table_name, :updated_by)
        change_table table_name do |t|
          t.column :updated_by, TemporalTables.updated_by_type
        end
      end

      add_index temporal_name(table_name), [:id, :eff_to] if options[:id] != false
      create_temporal_triggers table_name
      create_temporal_indexes table_name
    end

    def remove_temporal_table(table_name)
      return unless table_exists?(temporal_name(table_name))

      drop_temporal_triggers table_name
      drop_table_without_temporal temporal_name(table_name)
    end

    def drop_table(table_name, **options)
      super(table_name, **options)

      super(temporal_name(table_name), **options) if table_exists?(temporal_name(table_name))
    end

    def rename_table(name, new_name)
      drop_temporal_triggers name if table_exists?(temporal_name(name))

      super name, new_name

      return unless table_exists?(temporal_name(name))

      super(temporal_name(name), temporal_name(new_name))
      create_temporal_triggers new_name
    end

    def add_column(table_name, column_name, type, **options)
      super(table_name, column_name, type, **options)

      return unless table_exists?(temporal_name(table_name))

      super temporal_name(table_name), column_name, type, **options
      create_temporal_triggers table_name
    end

    def remove_columns(table_name, *column_names, **options)
      super(table_name, *column_names, **options)

      return unless table_exists?(temporal_name(table_name))

      super temporal_name(table_name), *column_names, **options
      create_temporal_triggers table_name
    end

    def remove_column(table_name, column_name, type = nil, **options)
      super(table_name, column_name, type, **options)

      return unless table_exists?(temporal_name(table_name))

      super temporal_name(table_name), column_name, type, **options
      create_temporal_triggers table_name
    end

    def change_column(table_name, column_name, type, **options)
      super(table_name, column_name, type, **options)

      return unless table_exists?(temporal_name(table_name))

      super temporal_name(table_name), column_name, type, **options
      # Don't need to update triggers here...
    end

    def rename_column(table_name, column_name, new_column_name)
      super(table_name, column_name, new_column_name)

      return unless table_exists?(temporal_name(table_name))

      super temporal_name(table_name), column_name, new_column_name
      create_temporal_triggers table_name
    end

    def add_index(table_name, column_name, **options)
      super(table_name, column_name, **options)

      return unless table_exists?(temporal_name(table_name))

      idx_name = temporal_index_name(options[:name] || index_name(table_name, column: column_name))
      super temporal_name(table_name), column_name, **options.except(:unique).merge(name: idx_name)
    end

    def remove_index(table_name, column_name = nil, **options)
      original_index_name = index_name_for_remove(table_name, column_name, options)
      super(table_name, column_name, **options)

      return unless table_exists?(temporal_name(table_name))

      idx_name = temporal_index_name(options[:name] || original_index_name)
      super temporal_name(table_name), column_name, name: idx_name
    end

    def create_temporal_indexes(table_name) # rubocop:disable Metrics/MethodLength
      indexes = ActiveRecord::Base.connection.indexes(table_name)

      indexes.each do |index|
        index_name = temporal_index_name(index.name)

        next if temporal_index_exists?(table_name, index_name)

        add_index(
          temporal_name(table_name),
          index.columns,
          # exclude unique constraints for temporal tables
          name: index_name,
          length: index.lengths,
          order: index.orders
        )
      end
    end

    def temporal_name(table_name)
      "#{table_name}_h"
    end

    def create_temporal_triggers(_table_name)
      raise NotImplementedError, 'create_temporal_triggers is not implemented'
    end

    def drop_temporal_triggers(_table_name)
      raise NotImplementedError, 'drop_temporal_triggers is not implemented'
    end

    # It's important not to increase the length of the returned string.
    def temporal_index_name(index_name)      
      temp_index_name = index_name.to_s.sub(/^index/, 'ind_h').sub(/_ix(\d+)$/, '_hi\1')
      temp_index_name = temporal_name(index_name) if temp_index_name == index_name
      temp_index_name
    end

    def temporal_index_exists?(table_name, index_name)
      index_name_exists?(temporal_name(table_name), index_name)
    end
  end
end
