class HGVBiblioIdentifier < HGVMetaIdentifier
  attr_reader :type_list, :bibliography_main, :bibliography_secondary, :xpath_main, :xpath_secondary, :plain_bibl_tags 

  FRIENDLY_NAME = "Bibliography"

  #def self.friendly_name
  #  return 'Bibliography'
  #end

  def self.find_by_publication_id publication_id
    return HGVMetaIdentifier.find_by_publication_id(publication_id).becomes(HGVBiblioIdentifier)
  end

  def self.find id
    return HGVMetaIdentifier.find(id).becomes(HGVBiblioIdentifier)
  end

  def after_initialize
    @type_list = [:main, :secondary]

    @xpath_main = "/TEI/teiHeader/fileDesc/sourceDesc/listBibl"
    @xpath_secondary = "/TEI/text/body/div[@type='bibliography'][@subtype='citations']/listBibl"

    @item_list_main = @item_list_secondary = {
      :language                => {:multiple => false, :xpath => "@xml:lang"},
      :signature               => {:multiple => false, :xpath => "idno[@type='signature']"},
      :title                   => {:multiple => false, :xpath => "title[@level='a'][@type='main']"},
      :author                  => {:multiple => true,  :xpath => "author"},
      :monographic_title       => {:multiple => false, :xpath => "title[@level='m'][@type='main']"},
      :monographic_title_short => {:multiple => false, :xpath => "title[@level='m'][@type='short']"},
      :series_title            => {:multiple => false, :xpath => "series/title[@level='s'][@type='main']"},
      :series_number           => {:multiple => false, :xpath => "series/biblScope[@type='volume']"},
      :journal_title_short     => {:multiple => false, :xpath => "monogr/title[@level='j'][@type='short']"},
      :journal_number          => {:multiple => false, :xpath => "monogr/biblScope[@type='volume']"},
      :editor                  => {:multiple => true,  :xpath => "editor"},
      :place_of_publication    => {:multiple => false, :xpath => "pubPlace"},
      :publication_date        => {:multiple => false, :xpath => "date"},
      :pagination              => {:multiple => false, :xpath => "biblScope[@type='page']"},
      :pagination_start        => {:multiple => false, :xpath => "biblScope[@type='page']/@from"},
      :pagination_end          => {:multiple => false, :xpath => "biblScope[@type='page']/@to"},
      :notes                   => {:multiple => false, :xpath => "notes"},
      :reedition               => {:multiple => false, :xpath => "relatedItem[@type='reedition'][@subtype='reference']/bibl[@type='publication'][@subtype='other']"}
    }

    @bibliography_main = {}
    @bibliography_secondary = {}

    @id_list_main = [:sb] # add further bilbiographies by extending the list, such as :xyz
    @bibl_tag_secondary = "bibl"
    @plain_bibl_tags = {}
  end

  def generate_empty_template_secondary
    generate_empty_template @item_list_secondary
  end

  def generate_empty_template item_list
    empty_template = {}
    item_list.each_pair {|key, value|
      empty_template[key] = ''
    }
    empty_template
  end

  def set_epidoc main, secondary, comment = 'update bibliographical information'

    xml = self.content

    if xml.empty?
      raise Exception.new 'no xml content found'
    end

    doc = REXML::Document.new xml

    main.each_pair {|id, data|
      store_bibliographical_data(doc, @item_list_main, data, xpath({:type => :main, :id => id}))
    }

    doc.elements.delete_all @xpath_secondary + '/' + @bibl_tag_secondary
    index = 0
    secondary.each_pair {|id, data|
      index += 1
      store_bibliographical_data(doc, @item_list_secondary, data, xpath({:type => :secondary, :id => index.to_s}))
    }

    modified_xml_content = ''
    formatter = REXML::Formatters::Default.new
    formatter.write doc, modified_xml_content

    self.set_content(modified_xml_content, :comment => comment)
  end

  def store_bibliographical_data doc, item_list, data, base_path
    docBibliography = doc.bulldozePath base_path

    item_list.each_pair {|key, options|
        path = base_path + '/' + options[:xpath]
        value = data[key.to_s].strip

        if options[:multiple]
          doc.elements.delete_all path

          splinters = value.split(',').select{ |splinter|
            (splinter.class == String) && (!splinter.strip.empty?)
          }

          splinters.each_index { |i|
            doc.bulldozePath(path + "[@n='" + (i + 1).to_s + "']", splinters[i].strip)
          }
        else
          doc.bulldozePath(path, value)
        end

      }
  end

  def get_epidoc_attributes
    
  end
  
  def retrieve_bibliographical_data
    doc = REXML::Document.new self.content
    
    retrieve_structured_bibliographical_data doc
    retrieve_plain_bibl_tags doc
  end

  def retrieve_structured_bibliographical_data doc

    @bibliography_main = {}
    @id_list_main.each {|id|
      @bibliography_main[id] = {}
      @item_list_main.each_key {|key|
        path = xpath({:type => :main, :id => id, :key => key})
        @bibliography_main[id][key] = extract_value(doc, path) # e.g. doc, '/TEI.../bibl.../title'
      }
    }

    @bibliography_secondary = {}
    doc.elements.each(xpath({:type => :secondary})) {|element|
      id = @bibliography_secondary.length + 1
      @bibliography_secondary[id] = {}
      @item_list_secondary.each_key {|key|
         path = xpath_tip(:secondary, key)
         @bibliography_secondary[id][key] = extract_value(element, path) # e.g. element, 'bibl.../title'
      }
    }

    prune @bibliography_secondary;
  end

  def prune bibliography
    bibliography.delete_if {|index, data|
      data_is_empty = true
      data.each_pair {|key, value|
        if !value.empty?
          data_is_empty = false
        end
      }
      data_is_empty
    }
  end

  def contains_plain_bibl_tags?
    @plain_bibl_tags.each_pair{|k, v|
      v.each{|l, w|
        return true
      }
    }
    false
  end

  def retrieve_plain_bibl_tags doc
    @plain_bibl_tags = {}

    type_list.each {|type|
      path = xpath_root(type) + '/bibl'
      @plain_bibl_tags[path] = {}

      doc.elements.each(path) {|element|
        text = ''
        element.each{|child|
          if child.type == REXML::Text
            text += child.value
          end
        }
        if !text.strip.empty?
          @plain_bibl_tags[path][@plain_bibl_tags[path].length] = text
        end
      }
    }
  end

  def xpath_root type = :main
    type == :main ? @xpath_main : (type == :secondary ? @xpath_secondary : '')
  end

  def xpath_base type, id = nil
    if type == :main && id
      "bibl[@id='" + id.to_s + "']"
    elsif type == :secondary
      @bibl_tag_secondary + (id ? "[@n='" + id.to_s + "']" : '')
    else
      raise Exception.new 'invalid type and id (' + type.to_s + ', ' + id.to_s + ')'
    end
  end

  def xpath_tip type, key
    if type == :main && @item_list_main.has_key?(key) && @item_list_main[key].has_key?(:xpath)
      @item_list_main[key][:xpath]
    elsif type == :secondary && @item_list_secondary.has_key?(key) && @item_list_secondary[key].has_key?(:xpath)
      @item_list_secondary[key][:xpath]
    else
      raise Exception.new 'invalid type and key (' + type.to_s + ', ' + key.to_s + ')'
    end
  end

  def xpath options = {}
    type = options[:type] || :main
    id   = options[:id]   || nil
    key  = options[:key]  || nil

    prefix = xpath_root(type)
    infix  = '/' + xpath_base(type, id)
    suffix = key ? ('/' + xpath_tip(type, key)) : ''

    prefix + infix + suffix
  end

  protected

  def extract_value document, element_path    
    tmp = ''

    if attribute = element_path[/\A([\w \[\]\/@:=']*?)(\/?@)([\w:]+)\Z/, 3] # i.e. path points to an attribute rather than an element
      document.elements.each($1) {|element|      
        tmp = element.attributes[attribute] || ''
      }
    else
      document.elements.each(element_path) {|element|
        if element.get_text
          tmp += element.get_text.value + ', '
        end
      }
    end

    return tmp.sub(/, \Z/, '')
  end

end
