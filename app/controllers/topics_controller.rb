class TopicsController < ApplicationController
  permit "site_admin or moderator or member or admin of :current_basket", :only => [ :new, :pick_topic_type, :create, :edit, :update]
  # put revert in here when we get to it
  permit "site_admin or moderator or admin of :current_basket", :only =>  [ :destroy ]

  # since we use dynamic forms based on topic_types and extended_fields
  # and topics have their main attributes stored in an xml doc
  # within their content field
  # in fact none of the topics table fields are edited directly
  # we don't do CRUD for topics directly
  # instead we override CRUD here, as well as show
  # and use app/views/topics/_form.rhtml to customize
  # we'll start with using the override syntax for ajaxscaffold
  # the code should easily transferred to something else if we decide to drop it

  ### TinyMCE WYSIWYG editor stuff
  uses_tiny_mce(:options => { :theme => 'advanced',
                  :browsers => %w{ msie gecko},
                  :mode => "textareas",
                  :theme_advanced_toolbar_location => "top",
                  :theme_advanced_toolbar_align => "left",
                  :theme_advanced_resizing => true,
                  :theme_advanced_resize_horizontal => false,
                  :paste_auto_cleanup_on_paste => true,
                  :theme_advanced_buttons1 => %w{ formatselect fontselect fontsizeselect bold italic underline strikethrough separator justifyleft justifycenter justifyright indent outdent separator bullist numlist forecolor backcolor separator link unlink image undo redo},
                  :theme_advanced_buttons2 => [],
                  :theme_advanced_buttons3 => [],
                  :theme_advanced_buttons3_add => %w{ tablecontrols fullscreen},
                  :editor_selector => 'mceEditor',
                  :plugins => %w{ contextmenu paste table fullscreen} },
                :only => [:new, :pick, :list, :create, :edit, :update, :pick_topic_type])
  ### end TinyMCE WYSIWYG editor stuff

  def index
    redirect_to_search_for('Topic')
  end

  # GETs should be safe (see http://www.w3.org/2001/tag/doc/whenToUseGet.html)
  verify :method => :post, :only => [ :pick_topic_type, :destroy, :create, :update ],
         :redirect_to => { :action => :list }

  def list
    index
  end

  def new
    @topic = Topic.new
  end

  def edit
    @topic = Topic.find(params[:id])
  end

  # this is code not generated by scaffold

  # the first step in creating a new topic
  # we need a topic_type to determine the proper form
  def pick_topic_type
  end

  # partially based on ajaxscaffold stuff, but basically are own code at this point
  def create
    begin
      # since this is creation, grab the topic_type fields
      topic_type = TopicType.find(params[:topic_type_id])
      params[:topic][:topic_type_id] = params[:topic_type_id]

      @fields = topic_type.topic_type_to_field_mappings

      # work through inherited fields as well as current topic_type
      @ancestors = TopicType.find(topic_type).ancestors
      # everything descends from topic topic_type,
      # so there is always at least one ancestor
      if @ancestors.size > 1
        @ancestors.each do |ancestor|
          @fields = @fields + ancestor.topic_type_to_field_mappings
        end
      end

      # ultimately I would like url's for peole to do look like the following:
      # topics/people/mcginnis/john
      # topics/people/mcginnis/john_marshall
      # topics/people/mcginnis/john_robert
      # for places:
      # topics/places/nz/wellington/island_bay/the_parade/206
      # events:
      # topics/events/2006/10/31
      # in the meantime we'll just use :name or :first_names and :last_names

      # here's where we populate the extended_content with our xml
      if @fields.size > 0
        extended_fields_update_param_for_item(:fields => @fields, :item_key => 'topic')
      end

      # in order to get the ajax to work, we put form values in the topic hash
      # in parameters, this will break new and update, because they aren't apart of the model
      # directly, so strip them out of parameters

      replacement_topic_hash = extended_fields_replacement_params_hash(:item_key => 'topic', :item_class => 'Topic')

      @topic = Topic.new(replacement_topic_hash)
      @successful = @topic.save

      # add this to the user's empire of creations
      # TODO: allow current_user whom is at least moderator to pick another user
      # as creator
      @topic.creators << current_user
    rescue
      flash[:error], @successful  = $!.to_s, false
    end

    where_to_redirect = 'show_self'
    if params[:relate_to_topic_id] and @successful
      # TODO: wrap this up into method
      # move to other controllers
      @new_related_topic = Topic.find(params[:relate_to_topic_id])
      ContentItemRelation.new_relation_to_topic(@new_related_topic, @topic)

      # update the related topic
      # so this new relationship is reflected in search
      prepare_and_save_to_zoom(@new_related_topic)

      where_to_redirect = 'show_related'
    end

    if @successful
      prepare_and_save_to_zoom(@topic)

      if where_to_redirect == 'show_related'
        # TODO: replace with translation stuff when we get globalize going
        flash[:notice] = 'Related topic was successfully created.'
        redirect_to_related_topic(@new_related_topic.id)
      else
        # TODO: replace with translation stuff when we get globalize going
        flash[:notice] = 'Topic was successfully created.'
        params[:topic] = replacement_topic_hash
        redirect_to :action => 'show', :id => @topic
      end
    else
        render :action => 'pick_topic_type'
    end
  end

  def update
    begin
      @topic = Topic.find(params[:id])
      topic_type = TopicType.find(@topic.topic_type_id)
      params[:topic][:topic_type_id] = params[:topic_type_id]

      @fields = topic_type.topic_type_to_field_mappings

      # work through inherited fields as well as current topic_type
      @ancestors = TopicType.find(topic_type).ancestors
      # everything descends from topic topic_type,
      # so there is always at least one ancestor
      if @ancestors.size > 1
        @ancestors.each do |ancestor|
          @fields = @fields + ancestor.topic_type_to_field_mappings
        end
      end

      if @fields.size > 0
        extended_fields_update_param_for_item(:fields => @fields, :item_key => 'topic')
      end

      # in order to get the ajax to work, we put form values in the topic hash
      # in parameters, this will break new and update, because they aren't apart of the model
      # directly, so strip them out of parameters

      replacement_topic_hash = extended_fields_replacement_params_hash(:item_key => 'topic', :item_class => 'Topic')

      @successful = @topic.update_attributes(replacement_topic_hash)

      # add this to the user's empire of contributions
      # TODO: allow current_user whom is at least moderator to pick another user
      # as contributor
      # uses virtual attr as hack to pass version to << method
      @current_user = current_user
      @current_user.version = @topic.version
      @topic.contributors << @current_user
    rescue
      flash[:error], @successful  = $!.to_s, false
    end

    params[:topic] = replacement_topic_hash

    if @successful
      prepare_and_save_to_zoom(@topic)

      # TODO: replace with translation stuff when we get globalize going
      flash[:notice] = 'Topic was successfully edited.'
      redirect_to :action => 'show', :id => @topic
    else
      render :action => 'edit'
    end
  end

  def destroy
    zoom_destroy_and_redirect('Topic')
  end

  ### end ajaxscaffold stuff

  # defaults to html if no extension
  # renders oai_record.rxml if xml request
  def show
    @topic = @current_basket.topics.find(params[:id])
    @title = @topic.title
    # TODO: likely to be inefficient, switch to more direct sql
    @creator = @topic.creators.first
    @last_contributor = @topic.contributors.last || @creator
    respond_to do |format|
      format.html
      format.xml { render_oai_record_xml(:item => @topic) }
    end
  end
end
