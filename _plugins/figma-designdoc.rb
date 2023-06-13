require 'dotenv'
require 'active_support/core_ext/string'
require 'net/http'
require 'uri'
require 'json'
require 'erb'
require 'rufus-scheduler'

class FigmaDesigndoc
  attr_accessor :structure

  def initialize(site)
    Dotenv.load

    # set figma token. Values in the .env always take precedence
    @figmatoken = ENV['FIGMATOKEN'] ? ENV['FIGMATOKEN'] : site.config["figmaconfig"]["token"]
    @figmadocuments = site.config["figmaconfig"]["documents"]
    @figmascale = site.config["figmaconfig"]["scale"]
    @figmaformat = site.config["figmaconfig"]["format"]
    @figmaurl = site.config["figmaconfig"]["figmaurls"]

    @assetpath = "site/assets"
    @pagespath = "site/pages"

    @structure = {}
    site.config["figmaconfig"]["updated"] ||= {}
  end

  def fetch(site)
    # Purge only the first time
    self.purgeFiles if site.config["figmaconfig"]["updated"].blank?

    @figmadocuments.each do |doc|

      content = JSON.parse self.getDoc(doc)
      raise StandardError.new(content["err"]) unless content["err"].nil?

      # Let's skip if we are polling the doc and we haven't changed anything
      skip = site.config["figmaconfig"]["updated"]["#{doc["document"]}"] == content["lastModified"] ? true: false
      site.config["figmaconfig"]["updated"]["#{doc["document"]}"] = content["lastModified"]

      pages = content["document"]["children"]

      # Let's generate a markdow per page
      pages.each do |page|
        if parseElement?(page["name"])
          item = self.writeMarkdown(doc, page, skip)
          (@structure["#{doc["category"]}"] ||= []) << item
        end
      end

    end

    self.buildMenu
  end

  # write a markdow document for each page
  def writeMarkdown(doc, page, skip)

    layers = page["children"].reverse
    pageid = page["id"]
    pagetitle = page["name"]
    figmadoc = doc["document"]
    filename = "#{pagetitle.parameterize}-#{figmadoc.parameterize}"
    blocks = []

    if(!skip)
      # Let's get the text layers
      text = layers.select do |layer|
        layer["type"] === "TEXT"
      end

      # Let's get only the frames
      frames = layers.select do |layer|
        layer["type"] === "FRAME" and self.parseElement?(layer["name"])
      end

      # let's build this
      frames.each do |frame|
        ftitle = self.showTitle?(frame["name"]) ? frame["name"] : nil
        fimage = self.getFrameImage(doc, page["name"], frame)
        ftext = self.getFrameText(text, frame["name"])
        fwidth = frame["absoluteBoundingBox"]["width"]

        block = {
          "title"     => ftitle,
          "image" => "/#{@assetpath}/#{fimage['filename']}",
          "figmaid"   => fimage['id'],
          "text"      => ftext,
          "width"     => fwidth
        }

        blocks.push(block)
      end


      # Do we have a summary?
      summary = text.select do |layer|
        layer["name"] == "_summary.md"
      end

      summary = summary.size > 0 ? summary.first["characters"] : nil

      # Do we have a tags?
      tags = text.select do |layer|
        layer["name"] == "_tags"
      end

      tags = tags.size > 0 ? tags.first["characters"] : nil
      menutag = !tags.nil? ? tags.split(",").first : nil


      # Export markdown from erb template
      template = File.read('_plugins/figma-template.md.erb')
      result = ERB.new(template).result(binding)

      open("#{@pagespath}/#{filename}.md", "wb") { |file|
        file.write(result)
        file.close
      }
    end

    {
      "title"     => pagetitle,
      "filename"  => filename,
      "tag"       => menutag
    }
  end

  # decidign if we should parse an element or not
  def parseElement?(string)
    return string.start_with?("~") ? false : true
  end

  # decidign if we should show the title above an element or not
  def showTitle?(string)
    return string.start_with?("_") ? false : true
  end

  # get the json of a given doc
  def getDoc(doc)
    uri = URI.parse("https://api.figma.com/v1/files/#{doc["document"]}")
    request = Net::HTTP::Get.new(uri)
    request["X-Figma-Token"] = @figmatoken

    req_options = {
      use_ssl: uri.scheme == "https",
    }

    response = Net::HTTP.start(uri.hostname, uri.port, req_options) do |http|
      http.request(request)
    end

    response.body
  end



  # Download the canvas as an image
  def getFrameImage(doc, pagename, canvas)

    uri = URI.parse("https://api.figma.com/v1/images/#{doc["document"]}?ids=#{canvas["id"]}&scale=#{@figmascale}&format=#{@figmaformat}")
    request = Net::HTTP::Get.new(uri)
    request["X-Figma-Token"] = @figmatoken

    req_options = {
      use_ssl: uri.scheme == "https",
    }

    response = Net::HTTP.start(uri.hostname, uri.port, req_options) do |http|
      http.request(request)
    end

    response = JSON.parse response.body

    # Download the image, return the name
    filename = "#{pagename.parameterize}-#{canvas["name"].parameterize}-#{canvas["id"].parameterize}-#{doc["document"].parameterize}.#{@figmaformat}"

    uri = URI.parse(response["images"][canvas["id"]])
    request = Net::HTTP::Get.new(uri)
    response = Net::HTTP.start(uri.hostname, uri.port, req_options) do |http|
      resp = http.get(uri.path)
      open("#{@assetpath}/#{filename}", "wb") { |file|
        file.write(resp.body)
        file.close
      }
    end

    {
      "filename" => filename,
      "id" => canvas['id']
    }
  end

  # Get the text associated with a frame
  def getFrameText(textlayers, framename)
    ftext = textlayers.select do |layer|
      layer["name"] == "#{framename}.md"
    end

    ftext.size > 0 ? ftext.first["characters"] : nil
  end

  # Build the menu templates
  def buildMenu
    template = File.read('_plugins/figma-menu.html.erb')
    result = ERB.new(template).result(binding)

    open("_includes/figma-menu.html", "wb") { |file|
      file.write(result)
      file.close
    }

  end

  # Remove files for regeneration
  def purgeFiles
    Dir["#{@pagespath}/*"].reject{ |f| f["#{@pagespath}/.keep"] }.each do |filename|
      File.delete filename
    end

    Dir["#{@assetpath}/*"].reject{ |f| f["#{@pagespath}/.keep"] }.each do |filename|
      File.delete filename
    end
  end

end


def fetchContent(site)
  figma = FigmaDesigndoc.new(site)
  figma.fetch(site)
  # writing the first page in the config
  key, value = figma.structure.first
  value = value.first["filename"]
  site.config["firstpage"] = value
end

# Generate everything we need after initializing the site
Jekyll::Hooks.register :site, :after_init do |site|
  fetchContent(site)
  if Jekyll::env == "figma-development"
    scheduler = Rufus::Scheduler.new
    scheduler.every '30s' do
      fetchContent(site)
    end
  end
end