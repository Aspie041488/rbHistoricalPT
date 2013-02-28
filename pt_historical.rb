
#!/usr/bin/env ruby

=begin

    This is a simple, headless, single-threaded Ruby script written to help illustrate the "work flow"
    of the Historical PowerTrack process.

    Currently this script does not stream the Historical data, but instead relies solely on the
    "flat-file" method of data delivery.

    For hopefully better and not worse, this script has a fair amount of comments.  It seems most Ruby code
    has very little comments since Ruby is so readable...  I included a lot of comments since I assume this
    example code will be reviewed by non-Ruby developers, and hopefully the extra narrative helps
    teach more about the Historical PowerTrack system.

    This script currently writes out to standard out fairly often with various information.  You may want to comment
    those out or redirect to a log file.  Also, be warned that this script currently has no error handling.

    A "status" setting gate-keeps the user through the workflow.  When the script is first executed with a new job
    description, it will submit the job, then move on to the "is quotation ready?" stage, loop there, resting 5
    minutes between checks.  Once the quote is ready, the job needs to be accepted or rejected.

        [Important Note: if you are test-driving Historical PowerTrack (or "trialing"), job acceptance/rejection
        will be a manual process (by Gnip staff) and can not be automated via the Historical PowerTrack API. Once
        you are in a subscription or on-demand contract, you'll be able to automate this approval process]

    Accepted quotes are launched, and then the job status is rechecked until the job is complete.  Historical jobs
    commonly take hours to complete, so this script checks the job status every five minutes until it is finished.

    Once finished, the script uses basic curl and linux commands to download and uncompress the files.
    Note: Windows users will likely need to override the downloadData and uncompressData methods.

    Here are the states a Historical Job passes through:
        #Possible states:
            # - new
            # - estimating --> triggers a 5-minute loop, waiting for job to be quoted.
            # - quoted
            # - accepted/rejected
            # - running   --> triggers a 5-minute loop, waiting for job to finish.
            # - finished  --> triggers code to download and uncompress files.


    There are two files passed into the 'constructor' of the PT Historical object:

        oHistPT = PtHistoricalJob.new("./MyConfig.yaml", "./jobDescriptions/MyJobDescription.yaml")

        Historical PowerTrack configuration file (MyConfig.yaml in this example) contains:

        config:
            account_name: <account_name>  #Used in URL for Historical API.
            user_name: <user_name>
            password_encoded: <EnCoDeDpAsSWoRd>
            stream_label: prod
            base_output_folder: ./output #Root folder for downloaded files.
            friendly_folder_names: true  #converts title into folder name by removing whitespace


        Job description file (MyJobDescription.yaml in this example) contains:

        job:
            #These will change from request to request.
            title: Test_4
            from_date: 201302010000
            #to_date: 201106010500
            to_date: 201302020000
            #These are 'static' values (more or less).
            service_name: gnip
            #These are optional, since they are defaults in code.
            publisher: twitter
            stream_type: track
            data_format: activity-streams

        #File with YAML-formatted rules.
        rules_file: ./rules/test.rules

    The Job Description file (MyJobDescription.yaml in this example) in turn references a YAML file containing the
    PowerTrack rules for the data retrieval.

        rules:
            - value  : (bounding_box:[-86.2 38.0 -85.743 38.35] OR bounding_box:[-85.743 38.0 -85.286 38.35] OR bounding_box:[-86.2 38.35 -85.743 38.7] OR bounding_box:[-85.743 38.35 -85.286 38.7])
            tag   : geo-louisville
            - value  : (rain OR flood OR storm OR weather)
            tag   : weather
            - value  : (rain OR precipitation OR flood) (inches OR in OR inch OR \")
            tag   : measurement
            - value  : ThisRuleWillNotMatchAndHasNoTag


    The Historical "PtHistoricalJob" object manages one Job in a single-threaded manner.  Code managing this class could
    spin up multiple objects.

    Classes offered here: PtHistoricalJob, JobDescription, PtREST, PtRules.
    Note: This version has the PtREST and PtRules classes included here.  These classes will soon become common classes,
    shared by multiple PowerTrack applications.

    Currently, Historical PowerTrack is only for Twitter. While this code is written in anticipation of
    expanding to other Publishers, there currently are these Job defaults:
            #publisher = "twitter" #(only Historical publisher currently)
            #product = "track"  #(only Historical product currently)

=end


#TODO: Add some error handling!
#TODO: Add some application logging.
#TODO: Confirm successful loading of all files.
#TODO: There should be smarter logic about rechecking the progress of a running job.  Start with a 5-minute pause,
#TODO: then re-calibrate the "sleep" duration...


require "net/https"     #HTTP gem.
require "uri"           #HTTP gem.
require "open-uri"      #Used in downloadFiles method.
require "json"          #PowerTrack speaks json.
require "yaml"          #Used for configuration, job and rules files.
require "base64"        #Basic encoding of passwords.
require "ostruct"       #Lightweight object.attribute helper.  Used for status structure.


class PtRules
    attr_accessor :rules

    def initialize
        @rules = Array.new
    end

    #Methods for maintaining the rules array ===========================================================================
    def addRule(value, tag=nil)
        #Gotta have a rule value, but tag is optional.
        rule = Hash.new
        rule[:value] = value
        if not tag.nil? then
            rule[:tag] = tag
        end
        #Add rule to rules array.
        @rules << rule
    end

    def deleteRule(value)   #No tag passed in, we remove with 'value' match.
                            #Regardless of tag, tour rules Array and remove.
        @rules.each do |r|
            if r[:value] == value then
                @rules.delete(r)
            end
        end
    end

    #Methods for getting the rules in the structure you want ==================================================
    def getJSON
        rulesPayload = Hash.new
        rulesPayload[:rules] = @rules
        rulesPayload.to_json
    end

    def getArray
        @rules
    end

    def getHash
        @rules
    end

    #Methods for loading rules from files ==============================================================================

    def loadRulesYAML(file)
        #Open file and parse, looking for rule/tag pairs
        ruleset = YAML.load_file(file)
        rules = ruleset["rules"]
        rules.each do |rule|
            #p rule
            @rules << rule
        end
    end

    def loadRulesJSON(file)
        #Open file and parse
        File.open(file, "r") do |f|
            rules = JSON.load(f)
        end
    end
end

class PtREST

    attr_accessor :url, :user_name, :password_encoded, :headers, :data, :data_agent

    def initialize(url=nil, user_name=nil, password_encoded=nil, headers=nil)
        if not url.nil?
            @url = url
        end

        if not user_name.nil?
            @user_name = user_name
        end

        if not password_encoded.nil?
            @password_encoded = password_encoded
            @password = Base64.decode64(@password_encoded)
        end

        if not headers.nil?
            @headers = headers
        end
    end

    def url=(value)
        @url = value
        @uri = URI.parse(@url)
    end

    def password_encoded=(value)
        @password_encoded=value
        @password = Base64.decode64(@password_encoded)
    end

    #Helper function for building URL ================================================================================

    def getHistoricalURL(account_name=nil)
        @url = "https://historical.gnip.com:443/accounts/"

        #TODO: error handling if there is no account_name available.

        if not account_name.nil? then
            @url = @url + account_name + "/jobs.json"
        else
            @url = @url + @account_name + "/jobs.json"
        end
    end

    #Fundamental REST API methods ======================================================================================
    def POST(data=nil)

        if not data.nil? #if request data passed in, use it.
            @data = data
        end

        uri = URI(@url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        request = Net::HTTP::Post.new(uri.path)
        request.body = @data
        request.basic_auth(@user_name, @password)
        response = http.request(request)
        return response
    end

    def PUT(data=nil)

        if not data.nil? #if request data passed in, use it.
            @data = data
        end

        uri = URI(@url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        request = Net::HTTP::Put.new(uri.path)
        request.body = @data
        request.basic_auth(@user_name, @password)
        response = http.request(request)
        return response
    end

    def GET
        uri = URI(@url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        request = Net::HTTP::Get.new(uri.path)
        request.basic_auth(@user_name, @password)
        response = http.request(request)
        return response
    end

    def DELETE(data=nil)
        if not data.nil?
            @data = data
        end

        uri = URI(@url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        request = Net::HTTP::Delete.new(uri.path)
        request.body = @data
        request.basic_auth(@user_name, @password)
        response = http.request(request)
        return response
    end
end

#=======================================================================================================================
#Historical PowerTrack Job Description.
#Simple helper class for reading in and handling job descriptions.
#Has methods for loading in a YAML job description file and returning as JSON.

class JobDescription

    attr_accessor :title, :to_date, :from_date, :stream_type, :rules_file, :rules, :service_name,
                  :publisher, :stream_type, :data_format

    def initialize
        #Defaults.
        @publisher = "twitter"
        @stream_type = "track"
        @data_format = "activity-streams"
    end

    def getConfig(config_file)

        config = YAML.load_file(config_file)

        #Job details.
        @title = config["job"]["title"]
        @to_date = config["job"]["to_date"]
        @from_date = config["job"]["from_date"]
        @service_name  = config["job"]["service_name"]
        @publisher  = config["job"]["publisher"]
        @stream_type = config["job"]["stream_type"]
        @data_format = config["job"]["data_format"]

        #Rules file in a YAML sequence format or it's a JSON file.
        @rules_file = config["rules_file"]
    end

    def getJobDescription

        #Create Rules object .
        oRules = PtRules.new
        #Create rules for this Job. Load rules from "rules_file" and add to job description.

        #if it is a .rules file then it is YAML...
        if @rules_file.split(".").last == "rules" then
            oRules.loadRulesYAML(@rules_file)
        else
            oRules.loadRulesJSON(@rules_file)
        end

        #Syntax for adding one rule at a time.
        #oRules.addRule("bounding_box[ ]", "geo")

        #Add Rules to Job description.
        @rules = oRules.getHash
        #p oJob.getJSON
        getJSON
    end


    #Returns job description in JSON.
    def getJSON
        job = {:title => @title, :publisher => @publisher, :toDate => @to_date.to_s, :fromDate => @from_date.to_s, :streamType => @stream_type,
               :dataFormat => @data_format, :serviceUsername => @service_name, :rules => @rules }
        job.to_json
    end

end #Job class.


#=======================================================================================================================
#Object for marshalling a Historical job through the process.
#One object per job.  Creates one HTTP and one Job object...

class PtHistoricalJob

    attr_accessor :http, :job, :uuid, :base_url, :url, :job_url, :account_name, :user_name, :password_encoded,
                  :stream_label, :base_output_folder, :output_folder, :friendly_folder_names,
                  :quote, :results

    def initialize(account_details_file, job_description_file)
        #class variables.
        @@base_url = "https://historical.gnip.com/accounts/"
        @@output_folder = "./output"

        getSystemConfig(account_details_file)  #Load the oHistorical PowerTrack account details.

        @url = constructURL  #Spin up Historical URL.

        #Set up a HTTP object.
        @http = PtREST.new  #Historical API is REST based (currently).
        @http.url = @url  #Pass the URL to the HTTP object.
        @http.user_name = @user_name  #Set the info needed for authentication.
        @http.password_encoded = @password_encoded  #HTTP class can decrypt password.

        #Set up a Job object.
        @job = JobDescription.new  #Create a Job object.
        @job.getConfig(job_description_file) #Load the configuration.

    end

    def getPassword
        #You may want to implement a more secure password handler.  Or not.
        @password = Base64.decode64(@password_encoded)  #Decrypt password.
    end

    def getSystemConfig(config_file)

        config = YAML.load_file(config_file)

        #Config details.
        @account_name = config["config"]["account_name"]
        @user_name  = config["config"]["user_name"]
        @password_encoded = config["config"]["password_encoded"]
        @stream_label = config["config"]["stream_label"]
        @base_output_folder = config["config"]["base_output_folder"]
        @friendly_folder_names = config["config"]["friendly_folder_names"]
    end

    '''
    Example list of jobs that have been submitted.  Payload includes job details, status, UUID (in job url), and expiration.
    {
        "jobs": [
            {
                "title": "Louisville Rain Events - April 2011 (testing Ruby code)",
                "jobURL": "https:\/\/historical.gnip.com:443\/accounts\/jim\/publishers\/twitter\/historical\/track\/jobs\/cp2ftan074.json",
                "status": "rejected",
                "publisher": "twitter",
                "streamType": "track",
                "fromDate": "201104110500",
                "toDate": "201104110500",
                "percentComplete": 0,
                "expiresAt": "2013-02-07T22:23:25Z"
            },
            {
                "title": "Louisville Rain Events - Spring 2011 (testing Ruby code)",
                "jobURL": "https:\/\/historical.gnip.com:443\/accounts\/jim\/publishers\/twitter\/historical\/track\/jobs\/ds4s8ygze6.json",
                "status": "estimating",
                "publisher": "twitter",
                "streamType": "track",
                "fromDate": "201103010500",
                "toDate": "201106010500",
                "percentComplete": 100,
                "expiresAt": "2013-02-07T22:42:17Z"
            }
        ]
    }
    '''
    def getJobList
        response = @http.GET  #Retrieve list of current jobs.
        response.body  #Response body contains a JSON list of jobs.
    end

    def new?(jobList)
        #p jobList
        #p jobList.to_s
        if jobList.include?(@job.title) then
            false
        else
            true
        end
    end

    #Returns UUID assigned to this job.
    def getUUID(jobs, title = nil)
        # if no title passed in, set to object instance value.
        if title.nil? then
            title = @job.title
        end

        #Load response into JSON and extract the UUID
        jobs = JSON.parse(jobs)
        jobs = jobs["jobs"]
        #p jobs.length
        jobs.each { |job|
            #p job
            if job["title"] == title then
                #Split the URL by "/", grab the last, then split by "." and grab the first.
                @job_url = job["jobURL"]
                @uuid  = @job_url.split("/").last.split(".").first
            end
        }
        @uuid
    end

    def constructURL(account_name=nil)
        if not account_name.nil? then
            return @@base_url + account_name + "/jobs.json"
        else
            return @@base_url + @account_name + "/jobs.json"
        end
    end

    '''
    Sets the @quote attribute.  Users can interrogate these fields and decide whether to process.
    In a manual approval use-case, these details would be presented to the user.

    "quote":
        {
        "costDollars": 5000,
        "estimatedActivityCount":10000,
        "estimatedDurationHours":12,
        "estimatedFileSizeMb": 10.0,
        "expiresAt": "2013-02-12T22:43:00Z"
        }
    '''
    def setQuoteDetails(job)
        @quote = {}
        job = JSON.parse(job)
        @quote = job["quote"]
    end

    '''
    Sets the @results attribute.
    This "results" hash provides information on how much data was retrieved and how to
    get the data.

    "results":
        {
        "completedAt":"2012-06 17T22:43:27Z",
        "activityCount":1200,
        "fileCount":1000,
        "fileSizeMb":10.0,
        "dataURL":"https://historical.gnip.com/accounts/<account_name>/publishers/twitter/historical/track/jobs/<job_uuid>/results.json"
        "expiresAt": "2012-06-30T22:43:00Z"
        }
    '''
    def setResultsDetails(job)
        @results = {}
        job = JSON.parse(job)
        @results = job["results"]
    end

    '''
    Parses the response from the Gnip Historical PT server and determines the Job status.

    "status" is an OpenStruct object.
    status.name => "new", "estimating", "quoted", "running",
    status.message = ""
    status.percent = 0
    status.quote = {}
    status.results = {}


    #TODO: grab a job being estimated.
    JobDescription being estimated: "status"=>"estimating", "percentComplete"=>94
    {"title"=>"Louisville Rain Events - Spring 2012", "jobURL"=>"https://historical.gnip.com:443/accounts/jim/publishers/twitter/historical/track/jobs/4rtd6mkk6p.json", "status"=>"estimating", "publisher"=>"twitter", "streamType"=>"track", "fromDate"=>"201203010500", "toDate"=>"201206010500", "percentComplete"=>94}

    -------- A quoted job, awaiting acceptance ----------------------------
    https://historical.gnip.com:443/accounts/jim/publishers/twitter/historical/track/jobs/waq3gxhg3f.json
        {
          "title": "Louisville Rain Events - Spring 2012",
          "account": "jim",
          "publisher": "twitter",
          "streamType": "track",
          "format": "activity-streams",
          "fromDate": "201203010500",
          "toDate": "201206010500",
          "requestedBy": "jmoffitt@gnipcentral.com",
          "requestedAt": "2013-02-20T20:53:22Z",
          "status": "quoted",
          "statusMessage": "Job quoted and awaiting customer acceptance.",
          "jobURL": "https:\/\/historical.gnip.com:443\/accounts\/jim\/publishers\/twitter\/historical\/track\/jobs\/4rtd6mkk6p.json",
          "quote": {
            "estimatedActivityCount": 7500,
            "estimatedDurationHours": "36.0",
            "estimatedFileSizeMb": "7.5",
            "expiresAt": "2013-02-27T21:00:32Z"
          },
          "percentComplete": 0
        }

    -------- A running job ----------------------------
    https://historical.gnip.com:443/accounts/jim/publishers/twitter/historical/track/jobs/waq3gxhg3f.json

        {
          "title": "Louisville Rain Events - May 28-31, 2012",
          "account": "jim",
          "publisher": "twitter",
          "streamType": "track",
          "format": "activity-streams",
          "fromDate": "201205280500",
          "toDate": "201206010500",
          "requestedBy": "jmoffitt@gnipcentral.com",
          "requestedAt": "2013-02-21T21:54:55Z",
          "status": "running",
          "statusMessage": "Job queued and being processed.",
          "jobURL": "https:\/\/historical.gnip.com:443\/accounts\/jim\/publishers\/twitter\/historical\/track\/jobs\/waq3gxhg3f.json",
          "quote": {
            "estimatedActivityCount": 250,
            "estimatedDurationHours": "3.0",
            "estimatedFileSizeMb": "1.0",
            "expiresAt": "2013-02-28T21:56:33Z"
          },
          "acceptedBy": "jmoffitt@gnip.com",
          "acceptedAt": "2013-02-21T22:18:44Z",
          "percentComplete": 41
        }
    '''
    def getStatus(jobInfo)
        status = OpenStruct.new
        status.name = "unknown"
        status.message = ""
        status.percent = 0

        #Are we parsing a job list? Or a specific job?
        if jobInfo.to_s.include?("\"jobs\":") then  #We are parsing a job list.
            p "Parsing a jobs list..."
            #OK, it this Job object's title in the list?  If not, this is a new job that needs to be submitted.
            if new?(jobInfo) then
                status.name = "new"
            else #this is NOT a new job so determine this job's status.
                 #load the @title job
                jobs = JSON.parse(jobInfo)
                jobs = jobs["jobs"]
                p jobs.length
                jobs.each { |job|

                    if job["title"] == @job.title then
                        p job
                        #What is its status?
                        status.name = job["status"]
                        status.percent = job["percentComplete"]
                        status.message = job["statusMessage"]

                        #grab @URL and @UUID while here
                        #Split the URL by "/", grab the last, then split by "." and grab the first.
                        @job_url = job["jobURL"]
                        @uuid  = @job_url.split("/").last.split(".").first
                    end
                }
            end
        else
            p "Parsing a single job: " + job.to_s
            #What is its status?
            job = JSON.parse(jobInfo)
            status.name = job["status"]
            status.percent = job["percentComplete"]
            status.message = job["statusMessage"]

            if jobInfo.include?("\"results\":") then  #this job is finished.
                p "Job is finished."
                status.name = "finished"
                status.percent = job["percentComplete"]
            end
        end

        status #return it...

    end

    '''
    Submit the Job to the Historical PowerTrack server.
    Check the server response.
    Return whether it was successfully submitted.
    '''
    def submitJob
        jobAdded = false

        #Submit Job for estimation.
        data = @job.getJobDescription
        response = @http.POST(data)

        #Read response and update status if successful...  Notify on problem.
        if response.code.to_i >= 200 and response.code.to_i < 300 then
            #Update status if OK
            jobAdded = true
            p "Job submitted, sleeping for one minute..."
            sleep (60*1)
        else
            p "HTTP error code: " + response.code + " | " + response.body  #Print HTTP error.
            jobAdded = false
        end

        jobAdded
    end

    '''
    Downloads file from the dataURL list of *.json end-points.  Current code below slices through the array
    of URLs, and then multi-threads to download each slice.

    Hardcoded slice size and number of threads are used below.  You may want to tune those or move them to the
    loaded configuration details.

    There are commented out code blocks that download files in a single-threaded fashion, and also a
    "curl | xargs" version that downloaded file using curl in a parallel fashion.


    When a job is FINISHED, here is what its payload looks like (notice the dataURL section, which leads you down
    the next step to getting your data).

   {"title":"Louisville Rain Events - Spring 2011 (testing Ruby code 4)",
    "account":"jim",
    "publisher":"twitter",
    "streamType":"track",
    "format":"activity-streams",
    "fromDate":"201103010500","toDate":"201106010500",
    "requestedBy":"jmoffitt@gnipcentral.com",
    "requestedAt":"2013-02-14T21:49:25Z",
    "status":"delivered",
    "statusMessage":"Job delivered and available for download.",
    "jobURL":"https://historical.gnip.com:443/accounts/jim/publishers/twitter/historical/track/jobs/axep43s8rv.json",
    "quote":{ "estimatedActivityCount":2500,
                "estimatedDurationHours":"12.0",
                "estimatedFileSizeMb":"2.5",
                "expiresAt":"2013-02-21T21:59:28Z"},
    "acceptedBy":"jmoffitt@gnipcentral.com",
    "acceptedAt":"2013-02-14T23:11:25Z",
    "results":{   "activityCount":1544,
                    "fileCount":1255,
                    "fileSizeMb":"1.44",
                    "completedAt":"2013-02-15T08:24:40Z",
                    "dataURL":"https://historical.gnip.com:443/accounts/jim/publishers/twitter/historical/track/jobs/axep43s8rv/results.json",
                    "expiresAt":"2013-03-01T23:12:22Z"},
    "percentComplete":100}

    Example dataURL contents:
    =========================
      "{"urlCount":1255,
        "urlList":["https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/01/13/20_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=zhB45aSYKVmzum%2Ftnxll7Mgjzgw%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/01/15/20_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=QPNF9c1RluhfvSFG3d66Vv9walc%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/01/21/30_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=9bIFhK6z9yAOJePeXcWuEwj6lBg%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/01/22/40_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=iFoKziBiGKpNhb8Dh%2F07SXYwKo4%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/02/00/40_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=LMfKA8ZK8T4fsfqx2SFpqdICBjY%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/02/02/20_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=SOcL1BPxUSZDHZsLY9owp7Up%2FzQ%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/02/10/20_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=EibcCOm5PRVnjp0ypX%2BRCbrxn3c%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/02/16/20_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=LBWDrWLQeLz85PvjxoFmYrcIotQ%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/02/16/30_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=gBMtUb%2FKxPYFycqrMQH%2BZ%2BHEu%2Fs%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/02/20/10_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=IAH0aMMJ9y0tNucrt%2FEs2TSJIus%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/03/03/20_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=yplDLZ66Z0Ed17Sae2lGTADZEw4%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/03/14/10_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=ygIz9zQ1wYaCU4xQTd%2FJH72s5TY%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/03/18/00_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=HY9PfmKaivHsFC61rfdZN03uwOQ%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/03/20/20_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=7utXSQr2nf%2FkpDCytPlGRaA5wwY%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/03/20/30_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=jGl4wCDeFNjTJhmg7ZnN%2B5qtpZI%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/03/20/40_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=8gQtczgFIU0%2FVjUebFpvmK5OvYc%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/03/21/00_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=vZy1kqCgWtDhIL2%2Btm2isQUCxV0%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/03/23/50_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=6fAje6Tl2ROa9UZ32jx50D9hU1I%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/04/00/00_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=Z6W0YLd%2BXoJZadkFn0jgRXCrHPA%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/04/11/40_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=ogCHDW%2BgPpZF8Q0Vp8Xnhg0RQBc%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/04/11/50_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=YdmuNfJSJjrru5fI6RIioKpDLdo%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/04/13/00_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=43dqX05Lr6PTbUaWoXM9g5wN1fM%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/04/14/10_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=4Op6LhdsOF8LplBvs7i9s0ENv54%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/04/19/00_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=EenQqNERirLCKwhU58XtvdKMYH4%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/04/20/50_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=RSCoI6vzOQshwZ40yHUCnSMyRbs%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/04/23/00_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=4q3Zr210usHnqtBKgyNTfyQnGWs%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/05/00/50_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=VnEKfAwflLz9UYvNNl0zrYBqQ%2B0%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/05/03/40_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=vfa2DL3DOg%2FsyER%2FZnYl5Dn0DCA%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/05/04/10_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=pKGMn1m4Ylgo%2FjbceURM%2F0tD5Xs%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/05/04/20_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=h6UPmFs8fNtIelZydXGBK1onWaU%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/05/11/50_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=n4tU%2FpdtCB9pJuHPJUoqQXVtxKo%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/05/12/10_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=3SEoUrWtx2OsM%2FzIlInaw2YBNtw%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/05/15/00_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=ePaGQanzT3RAY1uETzpDpWoljL8%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/05/15/10_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=uzKQbfRBCI6Pu%2Fq0jkYYHPEkV6A%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/05/16/00_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=nW2I4eALWGXeFlZ%2BnZmCG5ocoLk%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/05/18/30_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=ReticTz2Y%2BZSWgdAPwcCQ%2BeFaK4%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/05/19/10_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=V6zZuFywPZxNgFO1CumG%2Ft9fQZA%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/05/20/40_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=zVISAqMMR%2BYIkrhGVvR5NfiRSCU%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/05/23/10_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=s2rdEPmMeuXIAx1ooeb0BqJVr6Y%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/05/23/30_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=U%2F5fzXMmoV0685sK4PPuRPUwU%2BE%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/06/00/10_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=JELOf2LgYnD53R0Nmp4r2r%2Fjd1Q%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/06/00/40_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=rnL5CetxkOib6ETHX07b9r7zuWs%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/06/00/50_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=QK%2BMc%2BJpsrXmHMO12eOD%2FUYNPco%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/06/01/50_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=zwD0pWbOjUUp28koTYJHwXeGh5E%3D",
            "https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/06/06/10_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=OP1ibiwQurgu1ZUtCGdnaXB%2F89I%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/06/15/00_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=poN5TeTwFED%2FlLPWTjxa7%2BGPgGA%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/06/17/50_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=bKykTs1j8%2BscNC0qgvZ0jQnkiJo%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/07/06/40_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=NTPnx9237mG7VAdkv36f9oVttaM%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/07/10/30_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=3wFlY%2Fqy4RKKsJgaB%2F67UkQ633Y%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/07/10/40_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=SOs%2Bm2OmEf1Yi%2BvA5u60BHu6dmU%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/07/15/50_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=HNzdNkbCt7G2ryeAfiwoaJZyb4w%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/07/16/50_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=O5EnmWpEe9jG4GVv5mWnnnxha0c%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/08/00/50_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=hVNgnBqfvWXxtzpeVAc%2BPRfOmGU%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/08/01/50_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=6YpkBSk2f7nN5VgILYG1%2BgU%2FAG4%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/08/06/10_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=PrwJ4K4l9gYdFInAW6JxvakYDD8%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/08/11/10_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=i5Ejlz27R6CcJ1OivTqLaHXkjJ0%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/08/14/40_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=IpuqbE2%2FDNcxtLZFh7cNE33t5kI%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/08/15/20_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=hEhKbOC59EG%2Fp3Ei4Z7qRWCju7w%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/08/21/20_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=9xqZoK8xcetpZQFAU1n%2FO0%2FcUDA%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/08/22/10_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=rCNjWwuk7gZXTrGHgUy4gY2VFcQ%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/08/22/20_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=2wPU7mz%2Bi8Axtd54LrMOQ7bqlQ4%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/08/23/30_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=0GnNJDaJDbr1ts7CGn6ycbS5y1k%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/09/00/50_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=m86rW1cdY1B7s8qxMh%2FN%2FE9s1rw%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/09/04/10_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=WTkQu4aOa5r%2BQIyW%2BitM66NBzB8%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/09/04/20_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=9z%2Bn%2F5jbQRoCutXeJEQ3mbLyb0c%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/09/05/40_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=Zji1abXanh%2BeBhmpF1joI2iqaFw%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/09/05/50_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=n1OZpFcglMAFBrGWlj1k0D%2FWGH0%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/09/06/20_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=%2BePgr5ZCQBHx4IuI8uKW5fmydjg%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/09/06/40_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=bwmaOh9vfxR957SxjNXVRdhcxqY%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/09/07/10_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=HFeWTLuiQN%2Fd4d%2FQaykfVpZQ%2Bn0%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/09/07/50_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=%2F6GnIB6p60AQdMtJpkV6ILrI98o%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/09/12/30_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=zQxiWSLmmO%2F5jyBZJmoc4TU455U%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/09/12/50_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=CKQ8aaVsMJ8wiz%2Bx5Fs1L%2BGJ6e8%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/09/13/40_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=iEsrGNU2R6Gz9Jqbq9rOV0vst0M%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/09/13/50_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=yAWkEy6QbZzxphpiuXtuNd3qMRo%3D",
            "https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/09/14/00_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=DcQKPk5Mn0ljmYwV1%2BhO1bIFsPo%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/09/14/10_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=zgB43h6wrhfqZ4tfUWiDFmgT%2Fig%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/09/14/50_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=XwQvpU0nHWA51qgqSE1J2yc89Uo%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/09/15/50_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=pwd0KhATKgPt6B9wQM2ZQy8MPRk%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/09/16/10_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=oNSdvjkDuFM45%2FS853OgB9mkkfo%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/09/17/30_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=H86dz0G5JaKLxmw4vpMsK8RTpUo%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/09/17/40_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=UA%2B8X9%2FtGCP2QeOS07vlS9t0EDw%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/09/18/40_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=hdxtVKbSnICbT0nlMRyOBspqX%2FA%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/09/19/30_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=zCkI6O9rBHnDyDNqdhR%2FHLlhHh0%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/09/21/00_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=zmI0uR8gif9QqB14y%2BFagOHcr70%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/09/21/10_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=tczkq%2B8AQNMNm%2FqSSNXU0Hf07U8%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/09/21/20_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=G7kenBrAW7sY6Bqf0i0LiELf4yI%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/09/22/00_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=H8kIh%2FYxZeheyEZzLEoLiYQqY3M%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/09/22/40_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=syeYiJilBP3Q6og2HxSD4WI1dMM%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/10/02/00_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=ug9JmdyVM1zQBRLxbxvsbyHbOBE%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/10/02/10_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=F7m9rQUOHS6eL9vKPI7ewBWJgsg%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/10/02/20_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=qsxFIHQkWT1j04MygtyC1AtUnB0%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/10/03/10_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=fzfbeb7h3DTLz3krSd99MJp0EVY%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/10/06/00_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=yfGotMUGbTz0h3wfT%2FxGv0dBC2A%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/10/06/10_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=SObh8mX8xwF%2FUk2HQJSoK4cQZ0M%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/10/13/30_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=IvTOZX6IIao17XaHXYZpKbUDTbQ%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/10/15/00_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=uf%2BoGdAgU%2FxM0AZYedKH02VJOPA%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/10/17/40_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=OG9Hwwro%2BAhEN8bt4rFX1QGyH3c%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/10/18/20_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=StSO8f0v87tmP2rKmeCwVEn6cxc%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/10/21/00_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=mVouEy4JAGkvSfXejKLHbHdnSC0%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/10/22/10_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=MJugD5a5drQTtjQBy%2BaYmELj3fM%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/10/22/30_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=NLdIUB3OiokfbEePPfcx5JcWe94%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/10/23/40_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=ZQbBwQo4KfDwvnORuPSSO9yxGWI%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/11/01/00_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=es%2FNbqEpkbWUNRwjqCqXpxHdXBs%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/11/03/00_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=XfdkdLEP3JEqzqnBAGdnWW%2BiKCA%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/11/03/10_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=WEp3QovpyRB7diLdajXy%2B79HPrw%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/11/15/00_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=EXVMmsP%2BvzPHKjXdqfexGXGdLAM%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/11/20/50_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=5CwnypJd8Jeh2rLxjnlj8JCrN1Q%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/11/21/30_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=via8x9Q60aRyV%2Fs0a2W%2BN2L7RRM%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/11/22/30_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=imWqWN1QIR7STvwHFYQQnqepVQk%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/12/01/30_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=DxzDKyCqRThEclDGZypxAirKE9Y%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/12/03/50_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=OdE0Bo54EVwrb%2F9kaS%2F9a7G80D0%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/12/06/10_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=IKqf51ROb4tr7uS9Mj2Bobuf9nY%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/12/07/50_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=f1v7frcGCOIvo1dO9iRBpFOHM5E%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/12/13/10_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=YWohsCR9l1j6XX7cPLex3Eyv0lQ%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/12/18/00_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=QI5IsYA0s69sYe%2BSurFlcPLHK4g%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/12/21/30_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=4i1lPg7GbyGEwFjM7SgevZ3ObO8%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/13/07/40_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=IFsjGV%2BUPRgRrn%2BfVA7v3gQkZ%2FU%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/13/14/40_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=eZrQgxptgZyxhjfcXCXOpLk5r7A%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/13/21/00_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=aMOe7HMXOctr%2BVFxnmeq%2FiyuxYo%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/13/23/50_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=o2MXdgHrjWtxcL4eDxQqkOTj%2Bi8%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/14/00/00_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=%2BJu9b9qE2UwMvGotzZZlu5dk9Us%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/14/00/30_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=g%2BdnWIAhE3mAA1mO%2Ff3CZ%2FRt2Y4%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/14/08/50_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=JPJ6X%2FvKg4WgmHWcDdZgGCkrAJM%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/14/09/20_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=6g0TJReWsumelUPyAC2pJTC21c4%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/14/11/30_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=MUz%2BfCAcfGtFfhJ%2BeOVnnYApfI8%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/14/14/30_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=wKplQDvrKSlyiCpwGU%2FRFW3XvZE%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/14/17/30_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=d4lcWhvoQxKhmihpT29t%2FrAcJuk%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/14/18/10_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=H8%2FBJ7W4gn8KWaVL4hAyalK0XkA%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/14/21/00_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=ENouEMC1GT06G0dBSmzB5wAkqLs%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/15/00/10_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=RRd2bSKBBQR%2FYHH%2FfBkZIL48yCI%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/15/01/30_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=IE56SvffAayx%2BdML2pvHv5X7UzM%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/15/06/30_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=tOBCtmAjT%2F%2BYndoRU5oj%2FQNi4uw%3D","https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/03/15/07/10_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508679&Signature=lTQ0LUKG%2BXqN7YEMnOc7D4itxQw%3D",
            "https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/snapshots/twitter/track/activity-streams/jim/2013/02/14/20110301-20110601_axep43s8rv/2011/06/01/04/00_activities.json.gz?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508680&Signature=FHNkg0gSPRGDFtTizE03ZFHl780%3D"],
        "expiresAt":"2013-03-01T23:12:22Z",
        "totalFileSizeBytes":1518151,
        "suspectMinutesUrl":"https://s3-us-west-1.amazonaws.com/archive.replay.snapshots/customers/jim/20110301-20110601_axep43s8rv/suspectMinutes.json?AWSAccessKeyId=AKIAIJK6CC37HDLAJYHQ&Expires=1363508680&Signature=OKeY09i%2Fsvon3TKBznlBAQMLlxY%3D"
      }"
    '''

    def downloadData(jobInfo)

        #convert to JSON
        jobDetails = JSON.parse(jobInfo)

        #Set the HTTP object's URL to the "data" URL, and GET it.
        @http.url = jobDetails["results"]["dataURL"]
        dataURL = @http.GET

        #Parse the JSON end-point and load into a hash.
        urlInfo = JSON.parse(dataURL.body)
        urls = urlInfo["urlList"]

        p "Have this many files to download: " + urls.length.to_s

        #Since there could be thousands of files to fetch, let's throttle the downloading.
        #Let's process a slice at a time, then multiple-thread the downloading of that slice.
        slice_size = 30
        thread_limit = 30
        sleep_seconds = 1

        threads = []

        begin_time = Time.now

        urls.each_slice(slice_size) do |these_urls|
            p these_urls

            for file_url in these_urls

                threads << Thread.new(file_url) do |url|

                    until threads.map { |t| t.status }.count("run") < thread_limit do
                        print "."
                        sleep sleep_seconds
                    end

                    #Take URL and parse to create receiving file name.
                    name = url[url.index(@uuid)..(url.index(".gz?")+2)].gsub!("/","_")

                    File.open(@output_folder + "/" + name, "wb") do |saved_file|
                        # the following "open" is provided by open-uri
                        open(url, 'rb') do |read_file|
                            saved_file.write(read_file.read)
                            #print "MT: Saved " + name + " | "
                        end
                    end
                end

                threads.each { |thr| thr.join}
            end
        end

        p "Took #{Time.now - begin_time} seconds to download files.  "

=begin
  #Single-threaded method for downloading file.  Slow but simple.

        begin_time = Time.now

        urls.each { |url|

            #Take URL and parse to create receiving file name.
            name = url[url.index(@uuid)..(url.index(".gz?")+2)].gsub!("/","_")

            File.open(@output_folder + "/" + name, "wb") do |saved_file|
                # the following "open" is provided by open-uri
                open(url, 'rb') do |read_file|
                    saved_file.write(read_file.read)
                    p "Saved " + name
                end
            end
        }

        p "Time elapsed #{Time.now - begin_time} seconds."

=end

=begin
 #This is one example curl command that can download Historical data files in parallel.
        command = "cd " +  @output_folder + " ;curl -sS -u" + @user_name + ":" + getPassword + " https://historical.gnip.com/accounts/" + @account_name + "/publishers/twitter/historical/track/jobs/" + @uuid + "/results.csv | xargs -P 8 -t -n2 curl -o "

        p "Downloading files.  Running: " + command

        system(command)
=end

        p "Finished downloading files..."
    end

    '''
    Writes a file in the output folder with the suspectMinutesURL in it...
    '''
    def handleSuspectMinutes(jobInfo)
        file_name = "suspect_minutes.txt"

        #convert to JSON
        jobDetails = JSON.parse(jobInfo)

        url = jobDetails["suspectMinutesUrl"]

        if !url.nil? then
            @http.url = jobDetails["suspectMinutesUrl"]
            suspectInfo = @http.GET
            File.open(@output_folder + file_name, 'w') {|f| f.write(suspectInfo.body)}
        else
           p "No suspect minutes. "
        end
    end

    '''
    A simple wrapper to the gunzip command.  Provides a simplistic mechanism for uncompressing gz files on Linux or
    Mac OS.  For Windows developers, this should be replaced with more appropriate code.
    '''
    def uncompressData

        #Code to unzip
        command = "gunzip " + @output_folder + "/*.gz"
        system(command)

        #Code to delete *.gz
        #command = "rm " + @output_folder + "/*.gz"
        #system(command)

    end

    #A simple (silly?) wrappers to remove JSON formatting from Job object user.
    def acceptJob
        "{\"status\":\"accept\"}"


        #data = {}
        #data["status"] = "accept"
        #data.to_json
    end

    def rejectJob
        "{\"status\":\"reject\"}"
        #reject = "{\"status\":\"reject\"}"
        #reject.to_json
    end

    '''
    Sets up the output path for downloaded files.
    Based on the "base" output path from Historical PT config file and either the job UUID, or, if using "friendly
    folder" names, a subfolder based on the Job  title.
    '''
    def setOutputFolder(subfolder = nil)

        #if subfolder is not nil, then tack it onto the configured base folder
        if !subfolder.nil? then
            @output_folder = @base_output_folder + "/" + subfolder
        else #then build using job specifics.
            if @friendly_folder_names then
                @output_folder = @base_output_folder + "/" + @job.title.delete(" ")  #Remove spaces from title.
                @output_folder.gsub!(/[,()]/,'_') #Replace , ( ) characters with _
            else
                @output_folder = @base_output_folder + "/" + @uuid
            end
        end

        #Create this folder if it does not exist.
        if (!File.exist?(@output_folder)) then
            Dir.mkdir(@output_folder)
        end
    end

    #This method marshalls a job through the process...
    def manageJob

        jobList = getJobList  #We start by retrieving a list of our jobs.
        status = getStatus(jobList)  #Based on payload, determine status.  New job?  If not, where in process?
        p "Status of " + @job.title + " job: " + status.to_s

        #If this is a NEW job, assemble the Job description and submit it.
        #This includes managing this Job's rules.
        if status.name == "new" then
            if !submitJob then
                p "ERROR occurred with your Historical Job request. Quitting"
                exit(status = false)
            end
        end

        #Confirm job was submitted OK, ask the PowerTrack server again...
        #Whether this is a new job, or one already submitted, determine the Job UUID for current job.
        if status.name == "new" then
            response = @http.GET #Get the job list again, confirm it was submitted OK, and lead us to the uuid.
            jobList = response.body
            #TODO: confirm the current job is in list.
            status.name = "estimating"
        end

        @uuid = getUUID(jobList)  #This call sets both oJob.uuid and oJob.jobURL

        #From this point on, we are operating on the JOB URL.
        @http.url = @job_url #Update the HTTP object's URL to this Job's URL.
        setOutputFolder(@output_folder)  #Now that we have the uuid, set the output directory for the Historical daa.
        response = http.GET
        jobInfo = response.body

        status = getStatus(jobInfo)

        if status.name == "estimating" then  #loop until the estimate is finished and we've moved to "quoted"
            #Check to see if estimation is finished.  If not pause 5 minutes and recheck
            until status.name == "quoted"
                p "Estimate not ready yet, sleeping for 5 minutes..."
                sleep(5*60)
                response = @http.GET
                jobInfo = response.body
                status = getStatus(jobInfo)
            end
        end

        '''
        At this point the job has been quoted and is ready for approval or rejection.
        Therefore, there should be some mechanism to review the job quote details.
        In a system with a UI, the job quote would be presented for review.
        In this case we are just coding the acceptance (or rejection) of the job

        IMPORTANT NOTE: during Historical PowerTrack trials, the accept/reject process is
        not enabled through the API.  Instead Gnip will need to perform this manually.
        After an account becomes live with a subscription, then jobs can be accepted/rejected
        using the API.
        '''

        if status.name == "quoted" then
            #Display the quote
            setQuoteDetails(jobInfo)
            p "Job has been quoted. | " + @quote.to_s

            #Accept or Reject Job.
            response = @http.PUT(acceptJob.to_s) #Accept job.
            if response.code.to_i >= 200 and response.code.to_i < 300 then
                status.name = "accepted"
            else
                p "Job could not be accepted. "
            end
            #response = @oHTTP.POST(rejectJob) #Reject job.
            #status.name = "rejected"
        end

        #If accepted, monitor status of Job completion.
        if status.name == "accepted" or status.name == "running" then
            #Check to see if job is finished.  If not pause 5 minutes and recheck
            until status.name == "finished"
                p "Job is running... " + status.percent.to_s + "% finished."
                sleep(5*60)
                response = @http.GET
                jobInfo = response.body
                status = getStatus(jobInfo)
            end
        end

        #If completed, retrieve the files.
        #Server provides a JSON file with paths to the flatfiles...
        #These files can be downloaded in parallel to a local directory...
        #http://support.gnip.com/customer/portal/articles/745678-retrieving-data-for-a-delivered-job
        if status.name == "finished" then

            downloadData(jobInfo)
            handleSuspectMinutes(jobInfo)
            uncompressData

            #Code to load into database

        end
    end

end #PtHistorical class.


#-----------------------------------------
#Usage examples and unit testing:
#-----------------------------------------

if __FILE__ == $0  #This script code is executed when running this file.

    #Create a Historical PowerTrack object, passing in job description.
    oHistPT = PtHistoricalJob.new("./HistoricalPTConfig_private.yaml", "./jobDescriptions/HistoricalRequest.yaml")

    #The "do all" method, utilizes many other methods to complete a job.
    p oHistPT.manageJob
end
