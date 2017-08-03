#!/usr/bin/env ruby

# Extracts information about Carpentry workshops and instructors (per country) from AMY and saves them to CSV files.

require 'yaml'
require 'json'
require 'csv'
require 'fileutils'
require 'nokogiri'
require 'date'
require 'open-uri'
require 'optparse'
require 'ostruct'

VERSION = "1.0.0"

# Public JSON API URL to all 'published' instructor events that went or will go ahead (i.e. have country_code, address, start date, latitude and longitude, etc.)
AMY_API_PUBLISHED_WORKSHOPS_URL = "https://amy.software-carpentry.org/api/v1/events/published/"

# Private JSON API URL for all people that have a profile (but not necessarily an account) in AMY
AMY_API_ALL_PERSONS_URL = "https://amy.software-carpentry.org/api/v1/persons/"

# Private JSON API for getting all airports and their countries registered in AMY
AMY_API_ALL_AIRPORTS_URL = "https://amy.software-carpentry.org/api/v1/airports/"

AMY_UI_WORKSHOP_BASE_URL = "https://amy.software-carpentry.org/workshops/event"  # AMY_UI_WORKSHOP_BASE_URL/id gets the workshop id's page in HTML
AMY_UI_PERSON_BASE_URL = "https://amy.software-carpentry.org/workshops/person"  # AMY_UI_PERSON_BASE_URL/id gets the person id's page in HTML

# YAML config file with username/password to login to AMY (to be used if credentials are not passed as command line arguments)
AMY_LOGIN_CONF_FILE =  'amy_login.yml'

# All airports form AMY are serialised as JSON to this file
#AIRPORTS_FILE = 'airports.json'

# AMY login URL - for authenticated access, go to this URL first to authenticate and obtain sessionid and csrf_token for subsequent requests
AMY_LOGIN_URL = "https://amy.software-carpentry.org/account/login/"
HEADERS = {
    "User-Agent" => "Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:54.0) Gecko/20100101 Firefox/54.0",
    "Accept" => "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language" => "en-GB,en;q=0.5"
}

# Types of instructor badges in AMY
INSTRUCTOR_BADGES = ["swc-instructor", "dc-instructor", "trainer"]

# Data directory where we save the results
DATA_DIR = "#{File.expand_path(File.dirname(__FILE__))}/data"
FileUtils.mkdir_p(DATA_DIR) unless Dir.exists?(DATA_DIR)

def authenticate_with_amy(username = nil, password = nil)

  # Authentication with AMY involves mimicking the UI form authentication (i.e. mimic what is happening in the UI), since basic authN is not supported.
  # We first need to retrieve csrf_token passed to the client by the server (so we do an initial GET AMY_LOGIN_URL), then POST the csrf_token back alongside username and password (and also pass the csrf_token in headers).
  # In return, we get the session_id and the same csrf_token. We use these two for all subsequent calls to private pages and pass them in headers.
  if username.nil? and password.nil?
    if File.exist?(AMY_LOGIN_CONF_FILE)
      amy_login = YAML.load_file(AMY_LOGIN_CONF_FILE)
      username = amy_login['amy_login']['username']
      password  = amy_login['amy_login']['password']
    else
      puts "Failed to load AMY login details from #{AMY_LOGIN_CONF_FILE}: file does not exist."
      return nil, nil
    end
  end

  if username.nil? or password.nil?
    puts "Username or password are blank - cannot authenticate with AMY."
    return nil, nil
  else
    begin
      csrf_token = open(AMY_LOGIN_URL).meta['set-cookie'].scan(/csrftoken=([^;]+)/)[0][0]
      puts "Obtained csrf_token from AMY."

      amy_login_url = URI.parse(AMY_LOGIN_URL)
      headers = HEADERS.merge({
                                  "Referer" => AMY_LOGIN_URL,
                                  "Cookie" => "csrftoken=#{csrf_token}"
                              })

      http = Net::HTTP.new(amy_login_url.host, amy_login_url.port)
      http.use_ssl = true

      request = Net::HTTP::Post.new(amy_login_url.request_uri, headers)
      request.set_form_data("username" => username, "password" => password, "csrfmiddlewaretoken" => csrf_token)

      response = http.request(request)

      session_id = response['set-cookie'].scan(/sessionid=([^;]+)/)[0][0]
      puts "Obtained session_id from AMY."

      return session_id, csrf_token

    rescue Exception => ex
      puts "Failed to authenticate with AMY. An error of type #{ex.class} occurred, the reason being: #{ex.message}."
      puts "Backtrace:\n\t#{ex.backtrace.join("\n\t")}"
      return nil, nil
    end
  end
end

# Get info on 'published' workshops recorded in AMY, by country_code (or for all countries if country_code == nil or country_code == 'all').
# 'Published' workshops are those that went ahead or are likely to go ahead (i.e. have country_code, address, start date, end date, latitude and longitude, etc.)
def get_workshops(country_code, session_id, csrf_token)

  all_published_workshops = []  # all workshops in AMY that are considered 'published', i.e. have a venue, location , longitude, latitude, start and end date, etc.
  workshops_by_country = []
  begin
    # Retrieve publicly available workshop details using AMY's public API
    puts "Quering AMY's API at #{AMY_API_PUBLISHED_WORKSHOPS_URL} to get publicly available info for published workshops for country: #{country_code}."
    headers = HEADERS.merge({"Accept" => "application/json"})
    all_published_workshops = JSON.load(open(AMY_API_PUBLISHED_WORKSHOPS_URL, headers))

    # Get the workshops for the selected country_code, or all workshops if country_code == nil or country_code == 'all'
    workshops_by_country = all_published_workshops
    workshops_by_country = all_published_workshops.select{|workshop| workshop["country"] == country_code} unless (country_code.nil? or country_code == 'all')
    puts "Results: number of workshops for country #{country_code} = #{workshops_by_country.length.to_s}; total number of all workshops = #{all_published_workshops.length.to_s}."

    # Figure out some extra details about the workshops - e.g. the number of instructor attendees and instructors from AMY records - by accessing the UI/HTML page of each instructor - since this info is not available via the public API.
    # To do that, we need to extract the HTML table listing people and their roles (e.g. where role == 'learner' or where role == 'instructor').
    # Accessing these pages requires authentication passing session_id and csrf_token obtained previously.
    #get_private_workshop_info(workshops_by_country, session_id, csrf_token) unless (session_id.nil? or csrf_token.nil?)

  rescue Exception => ex
   puts "Failed to get publicly available workshops info using AMY's API at #{AMY_API_PUBLISHED_WORKSHOPS_URL}. An error of type #{ex.class} occurred, the reason being: #{ex.message}."
   puts "Backtrace:\n\t#{ex.backtrace.join("\n\t")}"
  end

  return workshops_by_country
end

def get_private_workshop_info(workshops, session_id, csrf_token)
  workshops.each_with_index do |workshop, index|
    begin
      puts "\n" + "#" * 80 +"\n\n"
      print "Processing workshop no. " + (index+1).to_s + " (#{workshop["slug"]}) from #{AMY_UI_WORKSHOP_BASE_URL + "/" + workshop["slug"]}" + "\n"

      # Add the Cookie header, as access to these pages needs to be authenticated
      headers = HEADERS.merge({"Cookie" => "sessionid=#{session_id}; token=#{csrf_token}"})
      workshop_html_page = Nokogiri::HTML(open(AMY_UI_WORKSHOP_BASE_URL + "/" + workshop["slug"], headers))

      if !workshop_html_page.xpath('//title[contains(text(), "Log in")]').empty?
        puts "Failed to get the HTML page for instructor #{workshop["slug"]} from #{AMY_UI_WORKSHOP_BASE_URL + "/" + workshop["slug"]} to parse it. You need to be authenticated to access this page."
        next
      end

      # Look at the attendance row in the HTML table
      # <tr class=""><td>attendance:</td><td colspan="2">   25   <a href="#" class="btn btn-primary btn-xs pull-right disabled">Ask for attendance</a></td></tr>
      # Note at_xpath method is used as we know there will be one element only
      attendance_number_node = workshop_html_page.at_xpath('//table/tr/td[contains(text(), "attendance:")]/../td[2]') # gets 2nd <td> child of a <tr> node that contains a <td> with the text 'attendance:'

      #workshop['number_of_attendees'] = workshop_html_page.xpath('//table/tr/td[contains(text(), "learner")]').length
      workshop['number_of_attendees'] = attendance_number_node.nil? ? 0 : attendance_number_node.content.slice(0, attendance_number_node.content.index("Ask for attendance")).strip.to_i
      puts "Found #{workshop["number_of_attendees"]} attendees for #{workshop["slug"]}."

      # Get instructors that taught at workshops
      instructors = workshop_html_page.xpath('//table/tr/td[contains(text(), "instructor")]/../td[3]')
      workshop['instructors'] = instructors.map(&:text) # Get text value of all instructor nodes as an array
      workshop['instructors'] += Array.new(10 - workshop['instructors'].length, '')  # append empty strings (if we get less then 10 instructors from AMY) as we have 10 placeholders for instructors and want csv file to be properly aligned
      workshop['instructors'] = workshop['instructors'][0,10] if workshop['instructors'].length > 10 # keep only the first 10 elements (that should be enough to cover all instructors, but just in case), so we can align the csv rows properly later on
      puts "Found #{workshop["instructors"].reject(&:empty?).length} instructors for #{workshop["slug"]}."
   rescue Exception => ex
     # Skip to the next workshop
     puts "Failed to get number of attendees for workshop #{workshop["slug"]} from #{AMY_UI_WORKSHOP_BASE_URL + "/" + workshop["slug"]}. An error of type #{ex.class} occurred, the reason being: #{ex.message}."
     puts "Backtrace:\n\t#{ex.backtrace.join("\n\t")}"
     next
    end
  end
end

def get_instructors(airports, session_id, csrf_token)

  puts "\n" + "#" * 80 +"\n\n"
  puts "Getting instructors' info, filtered per country via its airports."

  instructors = []

  if session_id.nil? or csrf_token.nil?
    puts "session_id or csrf_token are blank - cannot authenticate with AMY system to access #{AMY_API_ALL_PERSONS_URL}."
  else
    begin
      # Retrieve a list of all people that have a profile in AMY
      puts "Quering AMY's API at #{AMY_API_ALL_PERSONS_URL} to get available info on all registered people."
      headers = HEADERS.merge({"Accept" => "application/json", "Cookie" => "sessionid=#{session_id}; token=#{csrf_token}"})
      json = JSON.load(open(AMY_API_ALL_PERSONS_URL, headers))
      all_people = json["results"]
      # Results are paged so we need to do a few more queries to get all the results back
      next_page = json["next"]
      while !next_page.nil?
        puts "Querying " + next_page
        json = JSON.load(open(next_page, headers))
        all_people += json["results"]
        next_page = json["next"]
      end

      airport_iata_codes = airports.map{|airport| airport['iata']} unless airports.nil?
      puts "Looking for instructors with airport codes in " + airport_iata_codes.to_s unless airport_iata_codes.nil?
      # Filter out instructors (people with a non-empty badge field) by country (via a list of airports for a country). If airports is nil - return instructors for all airports/countries.
      all_people.each_with_index do |person, index|

        # To determine people from the UK, check the nearest_airport info, and, failing that, if email address ends in '.ac.uk' - that is our best bet.
        if airports.nil? # Include instructors from all airports/all countries
          instructors << person if !(INSTRUCTOR_BADGES & person['badges']).empty?
        else
          if !(INSTRUCTOR_BADGES & person['badges']).empty?  # The person has any of the instructor badges
            # Get the person airport's IATA code - the 3 characters before the last '/' in the airport field URI
            airport_iata_code = person['airport'].nil? ? nil : person['airport'][person['airport'].length - 4 , 3]
            if airport_iata_code.nil?
              instructors << person  # If airport code is nil then we cannot conclude where the person is from, so we have to include them
            elsif airport_iata_codes.include?(airport_iata_code)
              # Get the airport details based on the IATA code from person's profile
              airport = airport_iata_code.nil? ? nil : airports.select{|airport| airport["iata"] == airport_iata_code}[0]
              person["airport_iata_code"] = airport_iata_code
              person["airport_name"] = airport_iata_code.nil? ? nil : airport["fullname"]
              person["country_code"] = airport_iata_code.nil? ? nil : airport["country"]
              instructors << person
            end
          end
        end
      end

      #sleep(3700);

      # Get extra info about taught workshops for each of the filtered out instructors
      instructors.each do |instructor|
        tasks_url = instructor["tasks"]
        puts "Quering AMY's persons API at #{tasks_url} to get extra information on taught workshops for instructor #{instructor["personal"]} #{instructor["family"]}."
        headers = HEADERS.merge({"Accept" => "application/json", "Cookie" => "sessionid=#{session_id}; token=#{csrf_token}"})
        tasks = JSON.load(open(tasks_url, headers))
        # Find all ta tasks where the role was "instructor" then find that event's slug
        workshops_taught = tasks.map do |task|
          if task["role"] == "instructor"
            event_url = task["event"] # Events URL in AMY's API (contains slug), e.g. "https://amy.software-carpentry.org/api/v1/events/2013-09-21-uwaterloo/"
            event_url.scan(/([^\/]*)\//).last.first  # Find/emit event's slug - find all matching strings up to '/'
          end
        end.compact  # compact to eliminate nil values

        instructor["workshops_taught"] = workshops_taught
        instructor["number_of_workshops_taught"] = workshops_taught.length
      end
    rescue Exception => ex
     puts "Failed to get instructors using AMY's API at #{AMY_API_ALL_PERSONS_URL}. An error of type #{ex.class} occurred, the reason being: #{ex.message}."
     puts "Backtrace:\n\t#{ex.backtrace.join("\n\t")}"
    end
  end

  return instructors
end

def get_airports(country_code, session_id, csrf_token)
  puts "\n" + "#" * 80 +"\n\n"
  puts "Getting airport info so we can filter instructors per country."

  all_airports = []
  airports_by_country = []

  if session_id.nil? or csrf_token.nil?
    puts "session_id or csrf_token are blank - cannot authenticate with AMY system to access #{AMY_API_ALL_AIRPORTS_URL}."
  else
    begin
      # # Check if we already have the airports saved to a local file
      # if File.exists?(AIRPORTS_FILE)
      #   # Read airports from the file
      #   puts "Loading airport info saved to file #{AIRPORTS_FILE} at an earlier run."
      #   all_airports = JSON.parse(File.read(AIRPORTS_FILE))
      # else
        # Retrieve info about all airports available via AMY's API
        puts "Quering AMY's API at #{AMY_API_ALL_AIRPORTS_URL} to get info on airports in country: #{country_code}."
        headers = HEADERS.merge({"Accept" => "application/json", "Cookie" => "sessionid=#{session_id}; token=#{csrf_token}"})

        json = JSON.load(open(AMY_API_ALL_AIRPORTS_URL, headers))
        all_airports = json["results"]
        # Results are paged so we need to do a few more queries to get all the results back
        next_page = json["next"]
        while !next_page.nil?
          puts "Querying " + next_page
          json = JSON.load(open(next_page, headers))
          all_airports += json["results"]
          next_page = json["next"]
        end

        airports_by_country = all_airports
        airports_by_country = all_airports.select{|airport| airport["country"] == country_code} unless (country_code.nil? or country_code == 'all')

        # # Save all airports to a file for future use
        # File.open(AIRPORTS_FILE,"w") do |f|
        #   f.write( JSON.pretty_generate(all_airports))
        # end
      # end
    rescue Exception => ex
      puts "Failed to get airports info using AMY's API at #{AMY_API_ALL_AIRPORTS_URL}. An error of type #{ex.class} occurred, the reason being: #{ex.message}."
      puts "Backtrace:\n\t#{ex.backtrace.join("\n\t")}"
    end
  end
  return airports_by_country
end

def write_workshops_to_csv(workshops, csv_file)

  FileUtils.touch(csv_file) unless File.exist?(csv_file)
  # CSV headers
  csv_headers = ["slug", "humandate", "start", "end", "tags", "venue", "address", "latitude", "longitude", "eventbrite_id", "contact", "url", "number_of_attendees", "instructor_1", "instructor_2", "instructor_3", "instructor_4", "instructor_5", "instructor_6", "instructor_7", "instructor_8", "instructor_9", "instructor_10"]

  begin
    CSV.open(csv_file, 'w',
             :write_headers => true,
             :headers => csv_headers #< column headers
    ) do |csv|
      workshops.each do |workshop|
        csv << ([workshop["slug"],
                 workshop["humandate"],
                 (workshop["start"].nil? || workshop["start"] == '') ? DateTime.now.to_date.strftime("%Y-%m-%d") : workshop["start"],
                 (workshop["end"].nil? || workshop["end"] == '') ? ((workshop["start"].nil? || workshop["start"] == '') ? DateTime.now.to_date.next_day.strftime("%Y-%m-%d") : DateTime.strptime(workshop["start"], "%Y-%m-%d").to_date.next_day.strftime("%Y-%m-%d")) : workshop["end"],
                 workshop["tags"].map{|x| x["name"]}.join(", "),
                 workshop["venue"],
                 workshop["address"],
                 workshop["latitude"],
                 workshop["longitude"],
                 workshop["eventbrite_id"],
                 workshop["contact"],
                 workshop["url"],
                 workshop["number_of_attendees"],
                 workshop["instructors"]]).flatten  # flatten because instructor["instructors"] is an array and we want to concatenate each of its elements
      end
    end
    puts "\n" + "#" * 80 +"\n\n"
    puts "Finished writing workshop data for a total of #{workshops.length.to_s} workshops to file #{csv_file}."
    puts "\n" + "#" * 80 +"\n\n"
  rescue Exception => ex
    puts "\n" + "#" * 80 +"\n\n"
    puts "Failed to get export workshop data into #{csv_file}. An error of type #{ex.class} occurred, the reason being: #{ex.message}."
    puts "Backtrace:\n\t#{ex.backtrace.join("\n\t")}"
  end
end

def write_instructors_to_csv(instructors, csv_file)

  FileUtils.touch(csv_file) unless File.exist?(csv_file)
  # CSV headers
  csv_headers = ["name", "surname", "email", "amy_username", "country_code", "nearest_airport_name", "nearest_airport_code", "affiliation", "domains", "badges", "lessons", "number_of_workshops_taught", "workshops_taught"]

  begin
    CSV.open(csv_file, 'w',
             :write_headers => true,
             :headers => csv_headers #< column headers
    ) do |csv|
      instructors.each do |instructor|
        csv << ([instructor["personal"],
                 instructor["family"],
                 instructor["email"],
                 instructor["username"],
                 instructor["country_code"],
                 instructor['airport_name'],
                 instructor["airport_iata_code"],
                 instructor["affiliation"],
                 instructor["domains"],
                 instructor["badges"],
                 instructor["lessons"],
                 instructor["number_of_workshops_taught"],
                 instructor["workshops_taught"]])
      end
    end
    puts "\n" + "#" * 80 +"\n\n"
    puts "Finished writing instructor data for a total of #{instructors.length.to_s} instructors to file #{csv_file}."
    puts "\n" + "#" * 80 +"\n\n"
  rescue Exception => ex
    puts "\n" + "#" * 80 +"\n\n"
    puts "Failed to get export instructor data into #{csv_file}. An error of type #{ex.class} occurred, the reason being: #{ex.message}."
    puts "Backtrace:\n\t#{ex.backtrace.join("\n\t")}"
  end
end


# Parse command line parameters
# As per http://ruby-doc.org/stdlib-2.1.3/libdoc/optparse/rdoc/OptionParser.html
def parse(args)
  # The options specified on the command line will be collected in *options*.
  # We set the default values here.
  options = OpenStruct.new
  options.country_code = "GB"
  date = Time.now.strftime("%Y-%m-%d")
  options.workshops_file = File.join(DATA_DIR, "carpentry-workshops_GB_#{date}.csv")
  options.instructors_file = File.join(DATA_DIR, "carpentry-instructors_GB_#{date}.csv")

  opt_parser = OptionParser.new do |opts|
    opts.banner = "Usage: ruby extract-workshops-instructors.rb [-u USERNAME] [-p PASSWORD] [-c COUNTRY_CODE] [-w WORKSHOPS_FILE] [-i INSTRUCTORS_FILE]"

    opts.separator ""

    opts.on("-u", "--username USERNAME",
            "Username to use to authenticate to AMY") do |username|
      options.username = username
    end

    opts.on("-p", "--password PASSWORD",
            "Password to use to authenticate to AMY") do |password|
      options.password = password
    end

    opts.on("-c", "--country_code COUNTRY_CODE",
            "ISO-3166-1 two-letter country_code code or 'all' for all countries. Defaults to 'GB'.") do |country_code|
      options.country_code = country_code
      options.workshops_file = File.join(DATA_DIR, "carpentry-workshops_#{country_code}_#{date}.csv")
      options.instructors_file = File.join(DATA_DIR, "carpentry-instructors_#{country_code}_#{date}.csv")
    end

    opts.on("-w", "--workshops_file WORKSHOPS_FILE",
            "File name within 'data' directory where to save the workshops extracted from AMY to. Defaults to carpentry-workshops_COUNTRY_CODE_DATE.csv.") do |workshops_file|
      options.workshops_file = File.join(DATA_DIR, "#{workshops_file}")
    end

    opts.on("-i", "--instructors_file INSTRUCTORS_FILE",
            "File name within 'data' directory where to save the instructors extracted from AMY to. Defaults to carpentry-instructors_COUNTRY_CODE_DATE.csv.") do |instructors_file|
      options.instructors_file = File.join(DATA_DIR, "#{instructors_file}")
    end

    # A switch to print the version.
    opts.on_tail("-v", "--version", "Show version") do
      puts VERSION
      exit
    end

    # Print an options summary.
    opts.on_tail("-h", "--help", "Show this help message") do
      puts opts
      exit
    end

  end

  opt_parser.parse!(args)
  options
end  # parse()

# Main script body
if __FILE__ == $0 then

  options = parse(ARGV)

  # Accessing certain private pages requires authentication and obtaining session_id and csrf_token for subsequent calls.
  #session_id, csrf_token = authenticate_with_amy(options.username, options.password)
  session_id, csrf_token = nil, nil

  # Get all workshops for the selected country_code recorded in AMY
  workshops = get_workshops(options.country_code, session_id, csrf_token)

  # Get all airports for the selected country_code recorded in AMY
  #airports = get_airports(options.country_code, session_id, csrf_token)

  # Get all UK instructors recorded in AMY (we have to filter by the airport as it is the nearest airport that appears in people's profiles in AMY )
  #instructors = get_instructors(airports, session_id, csrf_token)

  write_workshops_to_csv(workshops, options.workshops_file) unless workshops.empty?
  #write_instructors_to_csv(instructors, options.instructors_file) unless instructors.empty?

end
