require 'simpleidn'
require 'resolv'
require 'netaddr'

module EmailAddress
  ##############################################################################
  # The EmailAddress Host is found on the right-hand side of the "@" symbol.
  # It can be:
  # * Host name (domain name with optional subdomain)
  # * International Domain Name, in Unicode (Display) or Punycode (DNS) format
  # * IP Address format, either IPv4 or IPv6, enclosed in square brackets.
  #   This is not Conventionally supported, but is part of the specification.
  # * It can contain an optional comment, enclosed in parenthesis, either at
  #   beginning or ending of the host name. This is not well defined, so it not
  #   supported here, expect to parse it off, if found.
  #
  # For matching and query capabilities, the host name is parsed into these
  # parts (with example data for "subdomain.example.co.uk"):
  # * host_name:         "subdomain.example.co.uk"
  # * dns_name:          punycode("subdomain.example.co.uk")
  # * subdomain:         "subdomain"
  # * registration_name: "example"
  # * domain_name:       "example.co.uk"
  # * tld:               "uk"
  # * tld2:              "co.uk" (the 1 or 2 term TLD we could guess)
  # * ip_address:        nil or "ipaddress" used in [ipaddress] syntax
  #
  # The provider (Email Service Provider or ESP) is looked up according to the
  # provider configuration rules, setting the config attribute to values of
  # that provider.
  ##############################################################################
  class Host
    attr_accessor :host_name, :dns_name, :domain_name, :registration_name,
                  :tld, :tld2, :subdomains, :ip_address, :config, :provider,
                  :comment
    MAX_HOST_LENGTH = 255

    # Sometimes, you just need a Regexp...
    DNS_HOST_REGEX  = / [\p{L}\p{N}]+ (?: (?: \-{1,2} | \.) [\p{L}\p{N}]+ )*/x

    # The IPv4 and IPv6 were lifted from Resolv::IPv?::Regex and tweaked to not
    # \A...\z anchor at the edges.
    IPv6_HOST_REGEX = /\[IPv6:
      (?: (?:(?x-mi:
      (?:[0-9A-Fa-f]{1,4}:){7}
         [0-9A-Fa-f]{1,4}
      )) |
      (?:(?x-mi:
      (?: (?:[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4})*)?) ::
      (?: (?:[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4})*)?)
      )) |
      (?:(?x-mi:
      (?: (?:[0-9A-Fa-f]{1,4}:){6,6})
      (?: \d+)\.(?: \d+)\.(?: \d+)\.(?: \d+)
      )) |
      (?:(?x-mi:
      (?: (?:[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4})*)?) ::
      (?: (?:[0-9A-Fa-f]{1,4}:)*)
      (?: \d+)\.(?: \d+)\.(?: \d+)\.(?: \d+)
      )))\]/ix

    IPv4_HOST_REGEX = /\[((?x-mi:0
               |1(?:[0-9][0-9]?)?
               |2(?:[0-4][0-9]?|5[0-5]?|[6-9])?
               |[3-9][0-9]?))\.((?x-mi:0
               |1(?:[0-9][0-9]?)?
               |2(?:[0-4][0-9]?|5[0-5]?|[6-9])?
               |[3-9][0-9]?))\.((?x-mi:0
               |1(?:[0-9][0-9]?)?
               |2(?:[0-4][0-9]?|5[0-5]?|[6-9])?
               |[3-9][0-9]?))\.((?x-mi:0
               |1(?:[0-9][0-9]?)?
               |2(?:[0-4][0-9]?|5[0-5]?|[6-9])?
               |[3-9][0-9]?))\]/x

    # Matches conventional host name and punycode: domain.tld, x--punycode.tld
    CANONICAL_HOST_REGEX = /\A #{DNS_HOST_REGEX} \z/x

    # Matches Host forms: DNS name, IPv4, or IPv6 formats
    STANDARD_HOST_REGEX = /\A (?: #{DNS_HOST_REGEX}
                              | #{IPv4_HOST_REGEX} | #{IPv6_HOST_REGEX}) \z/ix

    # host name -
    #   * host type - :email for an email host, :mx for exchanger host
    def initialize(host_name, config={})
      @original            = host_name ||= ''
      config[:host_type] ||= :email
      @config              = config
      parse(host_name)
    end

    # Returns the String representation of the host name (or IP)
    def name
      if self.ipv4?
        "[#{self.ip_address}]"
      elsif self.ipv6?
        "[IPv6:#{self.ip_address}]"
      elsif @config[:host_encoding] && @config[:host_encoding] == :unicode
        ::SimpleIDN.to_unicode(self.host_name)
      else
        self.dns_name
      end
    end
    alias :to_s :name

    # The canonical host name is the simplified, DNS host name
    def canonical
      self.dns_name
    end

    # Returns the munged version of the name, replacing everything after the
    # initial two characters with "*****" or the configured "munge_string".
    def munge
      self.host_name.sub(/\A(.{1,2}).*/) { |m| $1 + @config[:munge_string] }
    end

    ############################################################################
    # Parsing
    ############################################################################


    def parse(host) # :nodoc:
      host = self.parse_comment(host)

      if host =~ /\A\[IPv6:(.+)\]/i
        self.ip_address = $1
      elsif host =~ /\A\[(\d{1,3}(\.\d{1,3}){3})\]/ # IPv4
        self.ip_address = $1
      else
        self.host_name = host
      end
    end

    def parse_comment(host) # :nodoc:
      if host =~ /\A\((.+?)\)(.+)/ # (comment)domain.tld
        self.comment, host = $1, $2
      end
      if host =~ /\A(.+)\((.+?)\)\z/ # domain.tld(comment)
        host, self.comment = $1, $2
      end
      host
    end

    def host_name=(name)
      @host_name = name = name.strip.downcase.gsub(' ', '').gsub(/\(.*\)/, '')
      @dns_name  = ::SimpleIDN.to_ascii(self.host_name)

      # Subdomain only (root@localhost)
      if name.index('.').nil?
        self.subdomains = name

      # Split sub.domain from .tld: *.com, *.xx.cc, *.cc
      elsif name =~ /\A(.+)\.(\w{3,10})\z/ ||
            name =~ /\A(.+)\.(\w{1,3}\.\w\w)\z/ ||
            name =~ /\A(.+)\.(\w\w)\z/

        sub_and_domain, self.tld2 = [$1, $2] # sub+domain, com || co.uk
        self.tld = self.tld2.sub(/\A.+\./, '') # co.uk => uk
        if sub_and_domain =~ /\A(.+)\.(.+)\z/ # is subdomain? sub.example [.tld2]
          self.subdomains        = $1
          self.registration_name = $2
        else
          self.registration_name = sub_and_domain
          #self.domain_name = sub_and_domain + '.' + self.tld2
        end
        self.domain_name = self.registration_name + '.' + self.tld2
        self.find_provider
      end
    end

    def find_provider # :nodoc:
      return self.provider if self.provider

      EmailAddress::Config.providers.each do |provider, config|
        if config[:host_match] && self.matches?(config[:host_match])
          return self.set_provider(provider, config)
        end
      end

      return self.set_provider(:default) unless self.dns_enabled?

      provider = self.exchangers.provider
      if provider != :default
        self.set_provider(provider,
          EmailAddress::Config.provider(provider))
      end

      self.provider ||= self.set_provider(:default)
    end

    def set_provider(name, provider_config={}) # :nodoc:
      self.config = EmailAddress::Config.all_settings(provider_config, @config)
      self.provider = name
    end

    # Returns a hash of the parts of the host name after parsing.
    def parts
      { host_name:self.host_name, dns_name:self.dns_name, subdomain:self.subdomains,
        registration_name:self.registration_name, domain_name:self.domain_name,
        tld2:self.tld2, tld:self.tld, ip_address:self.ip_address }
    end

    ############################################################################
    # Access and Queries
    ############################################################################

    # Is this a fully-qualified domain name?
    def fqdn?
      self.tld ? true : false
    end

    def ip?
      self.ip_address.nil? ? false : true
    end

    def ipv4?
      self.ip? && self.ip_address.include?(".")
    end

    def ipv6?
      self.ip? && self.ip_address.include?(":")
    end

    ############################################################################
    # Matching
    ############################################################################

    # Takes a email address string, returns true if it matches a rule
    # Rules of the follow formats are evaluated:
    # * "example."  => registration name
    # * ".com"      => top-level domain name
    # * "google"    => email service provider designation
    # * "@goog*.com" => Glob match
    # * IPv4 or IPv6 or CIDR Address
    def matches?(rules)
      rules = Array(rules)
      return false if rules.empty?
      rules.each do |rule|
        return rule if rule == self.domain_name || rule == self.dns_name
        return rule if registration_name_matches?(rule)
        return rule if tld_matches?(rule)
        return rule if domain_matches?(rule)
        return rule if self.provider && provider_matches?(rule)
        return rule if self.ip_matches?(rule)
      end
      false
    end

    # Does "example." match any tld?
    def registration_name_matches?(rule)
      self.registration_name + '.' == rule ? true : false
    end

    # Does "sub.example.com" match ".com" and ".example.com" top level names?
    # Matches TLD (uk) or TLD2 (co.uk)
    def tld_matches?(rule)
      rule.match(/\A\.(.+)\z/) && ($1 == self.tld || $1 == self.tld2) ? true : false
    end

    def provider_matches?(rule)
      rule.to_s =~ /\A[\w\-]*\z/ && self.provider && self.provider == rule.to_sym
    end

    # Does domain == rule or glob matches? (also tests the DNS (punycode) name)
    # Requires optionally starts with a "@".
    def domain_matches?(rule)
      rule = $1 if rule =~ /\A@(.+)/
      return rule if File.fnmatch?(rule, self.domain_name)
      return rule if File.fnmatch?(rule, self.dns_name)
      false
    end

    # True if the host is an IP Address form, and that address matches
    # the passed CIDR string ("10.9.8.0/24" or "2001:..../64")
    def ip_matches?(cidr)
      return false unless self.ip_address
      return cidr if !cidr.include?("/") && cidr == self.ip_address

      c = NetAddr::CIDR.create(cidr)
      if cidr.include?(":") && self.ip_address.include?(":")
        return cidr if c.matches?(self.ip_address)
      elsif cidr.include?(".") && self.ip_address.include?(".")
        return cidr if c.matches?(self.ip_address)
      end
      false
    end

    ############################################################################
    # DNS
    ############################################################################

    # True if the :dns_lookup setting is enabled
    def dns_enabled?
      EmailAddress::Config.setting(:dns_lookup).equal?(:off) ? false : true
    end

    # True if the host name has a DNS A Record
    def has_dns_a_record?
      dns_a_record.size > 0 ? true : false
    end

    # Returns: [official_hostname, alias_hostnames, address_family, *address_list]
    def dns_a_record
      @_dns_a_record ||= Socket.gethostbyname(self.dns_name)
    rescue SocketError # not found, but could also mean network not work
      @_dns_a_record ||= []
    end

    # Returns an array of EmailAddress::Exchanger hosts configured in DNS.
    # The array will be empty if none are configured.
    def exchangers
      return nil if @config[:host_type] != :email || !self.dns_enabled?
      @_exchangers ||= EmailAddress::Exchanger.cached(self.dns_name)
    end

    # Returns a DNS TXT Record
    def txt(alternate_host=nil)
      Resolv::DNS.open do |dns|
        records = dns.getresources(alternate_host || self.dns_name,
                         Resolv::DNS::Resource::IN::TXT)
        records.empty? ? nil : records.map(&:data).join(" ")
      end
    end

    # Parses TXT record pairs into a hash
    def txt_hash(alternate_host=nil)
      fields = {}
      record = self.txt(alternate_host)
      return fields unless record

      record.split(/\s*;\s*/).each do |pair|
        (n,v) = pair.split(/\s*=\s*/)
        fields[n.to_sym] = v
      end
      fields
    end

    # Returns a hash of the domain's DMARC (https://en.wikipedia.org/wiki/DMARC)
    # settings.
    def dmarc
      self.dns_name ? self.txt_hash("_dmarc." + self.dns_name) : {}
    end

    ############################################################################
    # Validation
    ############################################################################

    # Returns true if the host name is valid according to the current configuration
    def valid?(rule=@config[:dns_lookup]||:mx)
      if self.provider != :default # well known
        true
      elsif self.ip_address
        @config[:host_allow_ip] && self.valid_ip?
      elsif rule == :mx
        self.exchangers.mxers.size > 0
      elsif rule == :a
        self.has_dns_a_record?
      elsif rule == :off
        self.to_s.size <= MAX_HOST_LENGTH
      else
        false
      end
    end

    # Returns true if the IP address given in that form of the host name
    # is a potentially valid IP address. It does not check if the address
    # is reachable.
    def valid_ip?
      if self.ip_address.nil?
        false
      elsif self.ip_address.include?(":")
        self.ip_address =~ Resolv::IPv6::Regex
      elsif self.ip_address.include?(".")
        self.ip_address =~ Resolv::IPv4::Regex
      end
    end

  end
end
