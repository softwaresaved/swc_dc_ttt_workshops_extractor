#!/usr/bin/env ruby

# Extracts JSON from https://amy.software-carpentry.org/api/v1/events/published/ containing all SWC, DC and TTT workshops
# that went ahead and then extracts those that were held in the UK and saves them to a CSV file.

require 'yaml'
require 'json'
require 'csv'
require 'fileutils'
require 'nokogiri'
require 'date'
require 'open-uri'

# Public JSON API URL to all workshop events that went ahead (i.e. have country, address, start date, latitude and longitude, etc.)
AMY_API_PUBLISHED_WORKSHOPS_URL = "https://amy.software-carpentry.org/api/v1/events/published"
AMY_UI_WORKSHOP_BASE_URL = "https://amy.software-carpentry.org/workshops/event"

# YML file with username/password to login to AMY
AMY_LOGIN_CONF_FILE =  'amy_login.yml'

# AMY login URL - for authenticated access, go to this URL first to authenticate and obtain sessionid and csrf_token for subsequent requests
AMY_LOGIN_URL = "https://amy.software-carpentry.org/account/login/"
HEADERS = {
    "User-Agent" => "Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:54.0) Gecko/20100101 Firefox/54.0",
    "Accept" => "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language" => "en-GB,en;q=0.5"
}

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
    puts "Username or password are blank - cannot authenticate with AMY system."
    return nil, nil
  else
    begin
      csrf_token = open(AMY_LOGIN_URL).meta['set-cookie'].scan(/csrftoken=([^;]+)/)[0][0]

      puts "Obtained csrf_token from AMY: #{csrf_token}"
      sleep (rand(5))

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

      return session_id, csrf_token

    rescue Exception => ex
      puts "Failed to authenticate with AMY. An error of type #{ex.class} occurred, the reason being: #{ex.message}."
      return nil, nil
    end
  end
end

def get_uk_workshops
  all_published_workshops = []  # all workshops in AMY that are considered 'published', i.e. have a venue, location , longitude, latitude and start and end date
  uk_workshops = []
  begin
    # Retrieve publicly available workshop details using AMY's public API
    puts "Quering AMY's API #{AMY_API_PUBLISHED_WORKSHOPS_URL} to get publicly available info for published workshops."
    headers = HEADERS.merge({"Accept" => "application/json"})
    all_published_workshops = JSON.load(open(AMY_API_PUBLISHED_WORKSHOPS_URL, headers))

  rescue Exception => ex
    puts "Failed to get publicly available workshop info using AMY's API at #{AMY_API_PUBLISHED_WORKSHOPS_URL}. An error of type #{ex.class} occurred, the reason being: #{ex.message}."
  else
    # Get the workshops in the UK
    uk_workshops = all_published_workshops.select{|workshop| workshop["country"] == "GB"}

    puts "Result stats: number of UK workshops = #{uk_workshops.length.to_s}; total number of all workshops = #{all_published_workshops.length.to_s}."
  end
  return uk_workshops
end

def get_private_workshop_info(workshops, session_id, csrf_token)
  workshops.each_with_index do |workshop, index|
    begin
      print "######################################################\n"
      print "Processing workshop no. " + (index+1).to_s + " (#{workshop["slug"]}) from #{AMY_UI_WORKSHOP_BASE_URL + "/" + workshop["slug"]}" + "\n"

      # Replace the Cookie headers info with the correct one, if you have access to AMY, as access to these pages needs to be authenticated
      headers = HEADERS.merge({"Cookie" => "sessionid=#{session_id}; token=#{csrf_token}"})

      workshop_html_page = Nokogiri::HTML(open(AMY_UI_WORKSHOP_BASE_URL + "/" + workshop["slug"], headers))
      # response = HTTParty.get(AMY_UI_WORKSHOP_BASE_URL + "/" + workshop["slug"],
      #                         headers: { Cookie: "sessionid=#{session_id}; token=#{csrf_token}", csrf_token: csrf_token })
      # workshop_html_page = Nokogiri::HTML(response.body)

      if !workshop_html_page.xpath('//title[contains(text(), "Log in")]').empty?
        puts "Failed to get the HTML page for workshop #{workshop["slug"]} from #{AMY_UI_WORKSHOP_BASE_URL + "/" + workshop["slug"]} to parse it. You need to be authenticated to access this page."
        next
      end

      # Look at the attendance row in the HTML table
      # <tr class=""><td>attendance:</td><td colspan="2">   25   <a href="#" class="btn btn-primary btn-xs pull-right disabled">Ask for attendance</a></td></tr>
      # Note at_xpath method is used as we know there will be one element only
      attendance_number_node = workshop_html_page.at_xpath('//table/tr/td[contains(text(), "attendance:")]/../td[2]') # gets 2nd <td> child of a <tr> node that contains a <td> with the text 'attendance:'

      #workshop['number_of_attendees'] = workshop_html_page.xpath('//table/tr/td[contains(text(), "learner")]').length
      workshop['number_of_attendees'] = attendance_number_node.blank? ? 0 : attendance_number_node.content.slice(0, attendance_number_node.content.index("Ask for attendance")).strip.to_i
      puts "Found #{workshop["number_of_attendees"]} attendees for #{workshop["slug"]}."

      instructors = workshop_html_page.xpath('//table/tr/td[contains(text(), "instructor")]/../td[3]')
      workshop['instructors'] = instructors.map(&:text) # Get text value of all instructor nodes as an array
      workshop['instructors'] += Array.new(10 - workshop['instructors'].length, '')  # append empty strings (if we get less then 10 instructors from AMY) as we have 10 placeholders for instructors and want csv file to be properly aligned
      workshop['instructors'] = workshop['instructors'][0,10] if workshop['instructors'].length > 10 # keep only the first 10 elements (that should be enough to cover all instructors, but just in case), so we can align the csv rows properly later on
      puts "Found #{workshop["instructors"].reject(&:empty?).length} instructors for #{workshop["slug"]}."
    rescue Exception => ex
      # Skip to the next workshop
      puts "Failed to get number of attendees for workshop #{workshop["slug"]} from #{AMY_UI_WORKSHOP_BASE_URL + "/" + workshop["slug"]}. An error of type #{ex.class} occurred, the reason being: #{ex.message}."
      next
    end
  end
end

def write_workshops_to_csv(uk_workshops, csv_file)
  # CSV headers
  csv_headers = ["slug", "humandate", "start", "end", "tags", "venue", "address", "latitude", "longitude", "eventbrite_id", "contact", "url", "number_of_attendees", "instructor_1", "instructor_2", "instructor_3", "instructor_4", "instructor_5", "instructor_6", "instructor_7", "instructor_8", "instructor_9", "instructor_10"]

  begin
    CSV.open(csv_file, 'w',
             :write_headers => true,
             :headers => csv_headers #< column headers
    ) do |csv|
      uk_workshops.each do |workshop|
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
                 workshop["instructors"]]).flatten  # flatten because workshop["instructors"] is an array and we want to concatenate each of its elements
      end
    end
    puts "\n" + "#" * 80 +"\n\n"
    puts "Finished writing workshop data into #{csv_file}."
    puts "Wrote a total of " + uk_workshops.length.to_s + " UK workshops."
    puts "\n" + "#" * 80 +"\n\n"
  rescue Exception => ex
    puts "\n" + "#" * 80 +"\n\n"
    puts "Failed to get export workshop data into #{csv_file}. An error of type #{ex.class} occurred, the reason being: #{ex.message}."
  end
end


if __FILE__ == $0 then
  # Get all UK workshops available via AMY's public API
  uk_workshops = get_uk_workshops()

  # Figure out some extra details about the workshops - e.g. the number of workshop attendees and instructors from AMY records - by accessing the UI/HTML page of each workshop - since this info is not available via the public API.
  # To do that, we need to extract the HTML table listing people and their roles (e.g. where role == 'learner' or where role == 'instructor').
  # Accessing these pages requires authentication and obtaining session_id and csrf_token for subsequent calls.
  session_id, csrf_token = authenticate_with_amy()

  get_private_workshop_info(uk_workshops, session_id, csrf_token) unless (session_id.nil? or csrf_token.nil?)

  date = Time.now.strftime("%Y-%m-%d")
  csv_file = "UK-carpentry-workshops_#{date}.csv"
  FileUtils.touch(csv_file) unless File.exist?(csv_file)

  write_workshops_to_csv(uk_workshops, csv_file)
end
