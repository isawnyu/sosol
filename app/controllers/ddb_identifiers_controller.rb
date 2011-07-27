class DdbIdentifiersController < IdentifiersController
  layout 'site'
  before_filter :authorize
  
  # GET /publications/1/ddb_identifiers/1/edit
  def edit
    find_identifier
    
    if @identifier.is_reprinted?
      reprint_identifier_string = [NumbersRDF::NAMESPACE_IDENTIFIER, @identifier.class::IDENTIFIER_NAMESPACE, @identifier.reprinted_in.to_s].join('/')
      reprint_identifier = @identifier.publication.identifiers.to_ary.find {|i| i.name == reprint_identifier_string}
      if !reprint_identifier.nil?
        reprint_identifier_path = polymorphic_path([@identifier.publication, reprint_identifier], :action => :edit)
        flash.now[:notice] = "This text is reprinted in <a href='#{reprint_identifier_path}'>#{reprint_identifier.title}</a>. Please <a href='#{reprint_identifier_path}'>edit the text there</a>, or <a href='#{polymorphic_path([@identifier.publication, @identifier], :action => :editxml)}'>edit this text's XML</a> to reflect the correct reprint relationship."
      else
        flash.now[:notice] = "This text is reprinted in #{reprint_identifier_string}, which is not associated with this publication (possibly a bug). Please edit the text there, or  <a href='#{polymorphic_path([@identifier.publication, @identifier], :action => :editxml)}'>edit this text's XML</a> to reflect the correct reprint relationship."
      end
    end
    
    begin
      # use a fragment cache for cases where we'd need to do a leiden transform
      if fragment_exist?(:action => 'edit', :part => "leiden_plus_#{@identifier.id}")
        @identifier[:leiden_plus] = read_fragment(:action => 'edit', :part => "leiden_plus_#{@identifier.id}")
      else
        if(defined?(XSUGAR_STANDALONE_ENABLED) && XSUGAR_STANDALONE_ENABLED)
          original_xml = DDBIdentifier.preprocess(@identifier.xml_content)

          # strip xml:id from lb's
          original_xml = JRubyXML.apply_xsl_transform(
            JRubyXML.stream_from_string(original_xml),
            JRubyXML.stream_from_file(File.join(RAILS_ROOT,
              %w{data xslt ddb strip_lb_ids.xsl})))

          # get div type=edition from XML in string format for conversion
          abs = DDBIdentifier.get_div_edition(original_xml).to_s
          
          if @identifier.get_broken_leiden.nil?  
            @identifier[:leiden_plus] = abs
          else
            @identifier[:leiden_plus] = nil
            @bad_leiden = true
          end
          
        else
          @identifier[:leiden_plus] = @identifier.leiden_plus
        end
        write_fragment({:action => 'edit', :part => "leiden_plus_#{@identifier.id}"}, @identifier[:leiden_plus])
      end
      if @identifier[:leiden_plus].nil?
        flash.now[:error] = "File loaded from broken Leiden+"
        @identifier[:leiden_plus] = @identifier.get_broken_leiden
      end
    rescue RXSugar::XMLParseError => parse_error
      flash.now[:error] = "Error parsing XML at line #{parse_error.line}, column #{parse_error.column}"
      new_content = insert_error_here(parse_error.content, parse_error.line, parse_error.column)
      @identifier[:leiden_plus] = new_content
    end
  end
  
  # PUT /publications/1/ddb_identifiers/1/update
  def update
    find_identifier
    @bad_leiden = false
    @original_commit_comment = ''
    #if user fills in comment box at top, it overrides the bottom
    if params[:commenttop] != nil && params[:commenttop].strip != ""
      params[:comment] = params[:commenttop]
    end
    if params[:commit] == "Save With Broken Leiden+" #Save With Broken Leiden+ button is clicked
      @identifier.save_broken_leiden_plus_to_xml(params[:ddb_identifier_leiden_plus], params[:comment])
      @bad_leiden = true
      flash.now[:notice] = "File updated with broken Leiden+ - XML and Preview will be incorrect until fixed"
      expire_leiden_cache
      expire_publication_cache
        @identifier[:leiden_plus] = params[:ddb_identifier_leiden_plus]
        render :template => 'ddb_identifiers/edit'
    else #Save button is clicked
      begin
        commit_sha = @identifier.set_leiden_plus(params[:ddb_identifier_leiden_plus],
                                    params[:comment])
        if params[:comment] != nil && params[:comment].strip != ""
          @comment = Comment.new( {:git_hash => commit_sha, :user_id => @current_user.id, :identifier_id => @identifier.origin.id, :publication_id => @identifier.publication.origin.id, :comment => params[:comment], :reason => "commit" } )
          #escaping the comment was the only way to get the DB to store special math symbols 𐅵𐅷𐅸 if there - not likely here but possible
          #character reference &#x10175; &#x10177; &#x10178; or javacode escape \ud800\udd75 \ud800\udd77 \ud800\udd78
          @comment.comment = CGI.escape(@comment.comment)
          @comment.save
        end
        flash[:notice] = "File updated."
        expire_leiden_cache
        expire_publication_cache
        if %w{new editing}.include?@identifier.publication.status
          flash[:notice] += " Go to the <a href='#{url_for(@identifier.publication)}'>publication overview</a> if you would like to submit."
        end
        
        redirect_to polymorphic_path([@identifier.publication, @identifier],
                                     :action => :edit)
      rescue RXSugar::NonXMLParseError => parse_error
        flash.now[:error] = "Error parsing Leiden+ at line #{parse_error.line}, column #{parse_error.column}.  This file was NOT SAVED. "
        new_content = insert_error_here(parse_error.content, parse_error.line, parse_error.column)
        @identifier[:leiden_plus] = new_content
        @bad_leiden = true
        @original_commit_comment = params[:comment]
        render :template => 'ddb_identifiers/edit'
      rescue JRubyXML::ParseError => parse_error
        flash.now[:error] = parse_error.to_str + 
          ".  This message is because the XML created from Leiden+ below did not pass Relax NG validation.  This file was NOT SAVED. "
        @bad_leiden = true #to keep from trying to parse the L+ as XML when render edit template
        @identifier[:leiden_plus] = params[:ddb_identifier_leiden_plus]
        render :template => 'ddb_identifiers/edit'
      end #begin
    end #when
  end
  
  def commentary
    find_identifier

    @identifier[:html_preview] = 
    JRubyXML.apply_xsl_transform(
      JRubyXML.stream_from_string(
        DDBIdentifier.preprocess(@identifier.xml_content)),
      JRubyXML.stream_from_file(File.join(RAILS_ROOT,
        %w{data xslt ddb commentary.xsl})),
        {})
      
  end
  
  def update_commentary
    find_identifier
    
    begin

      @identifier.update_commentary(params[:line_id], params[:reference], params[:content], params[:original_item_id])
      flash[:notice] = "File updated with new commentary."

      redirect_to polymorphic_path([@identifier.publication, @identifier],
                                   :action => :commentary)

    rescue JRubyXML::ParseError => parse_error
      flash[:error] = parse_error.to_str + 
          ".  This message is because the XML created from Front Matter Leiden below did not pass Relax NG validation.  This file was NOT SAVED. "
     
      redirect_to polymorphic_path([@identifier.publication, @identifier],
                                   :action => :commentary)
    end
  end
  
  def update_frontmatter_commentary
    find_identifier
    
    begin

      @identifier.update_frontmatter_commentary(params[:content])

      flash[:notice] = "File updated with new commentary."

      redirect_to polymorphic_path([@identifier.publication, @identifier],
                                   :action => :commentary)
    rescue JRubyXML::ParseError => parse_error
      flash[:error] = parse_error.to_str + 
          ".  This message is because the XML created from Front Matter Leiden below did not pass Relax NG validation.  This file was NOT SAVED. "
      
      redirect_to polymorphic_path([@identifier.publication, @identifier],
                                   :action => :commentary)
    end
  end
  
  def delete_frontmatter_commentary
    find_identifier
    
    @identifier.update_frontmatter_commentary('',true)
    
    flash[:notice] = "Front matter commentary entry removed."
    
    redirect_to polymorphic_path([@identifier.publication, @identifier],
                                 :action => :commentary)
  end
  
  def delete_commentary
    find_identifier
    
    @identifier.update_commentary(params[:line_id], params[:reference], params[:content], params[:original_item_id], true)
    
    flash[:notice] = "Commentary entry removed."
    
    redirect_to polymorphic_path([@identifier.publication, @identifier],
                                 :action => :commentary)
  end
  
  # GET /publications/1/ddb_identifiers/1/preview
  def preview
    find_identifier
    
    # Dir.chdir(File.join(RAILS_ROOT, 'data/xslt/'))
    # xslt = XML::XSLT.new()
    # xslt.xml = REXML::Document.new(@identifier.xml_content)
    # xslt.xsl = REXML::Document.new File.open('start-div-portlet.xsl')
    # xslt.serve()

    @identifier[:html_preview] = @identifier.preview
  end
  
  protected
    def find_identifier
      @identifier = DDBIdentifier.find(params[:id])
    end
  
    def find_publication_and_identifier
      @publication = Publication.find(params[:publication_id])
      find_identifier
    end
end
