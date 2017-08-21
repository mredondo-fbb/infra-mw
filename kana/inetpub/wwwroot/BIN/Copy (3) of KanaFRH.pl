#!/usr/bin/perl -w
    
# Kana Form Request Handler -- packages for handling web form
#   requests, and for generating and sending KXMF messages.
#
# Copyright 2000, Kana Communications, Inc. All rights reserved.
   
use strict;
use 5.005;
use CGI; 
use CGI::Carp qw(carpout);

BEGIN {
    sub fixDirName($) { my $dir = $_[0]; if ($dir =~ /[\\|\/]$/) { return $dir; } else { return $dir.'/'; } }

#
# To modify the MIME Content-Transfer-Encoding, simply comment out the first line
# below and uncomment one of the following lines.
# 
#    $KXMF::contentTransferEncoding = 'binary';
     $KXMF::contentTransferEncoding = 'quoted-printable';
#    $KXMF::contentTransferEncoding = 'base64';
#    $KXMF::contentTransferEncoding = '8bit';


#
# To modify the properties file directory, edit the line below, replacing 
# '/home/httpd/properties/' with the path to the desired  directory.
# 
    $CGIHandler::propertiesPath = 'D:/KanaForms/properties/';

    $CGIHandler::propertiesPath = fixDirName($CGIHandler::propertiesPath);
    my $logDirectory;    

#
# To modify the log file directory, edit the line below, replacing 
# '/home/httpd/properties/logs/' with the path to the desired  directory.
#
    $logDirectory = 'D:/KanaForms/properties/logs/';
        
    open (LOG, ">>".fixDirName($logDirectory)."frh-err.log") or
        die("Unable to open FRH error log: $!\n");
    carpout(\*LOG);

    $CGIHandler::messageLogPath = fixDirName($logDirectory);
    
# The following line defines the maximum acceptable input data size, 
# to prevent denial-of-service attacks. The default value is 1 MB
    $CGI::POST_MAX=1048576;  # max 1mb posts, value in bytes

# Uncommenting the following line disables file uploads entirely. 
#   $CGI::DISABLE_UPLOADS = 1;  # no uploads
    }
    
# Comment out or delete the call to "CGIHandler::handleRequest();"
#   if you are going to be using the FRH as a library.
#
# Uncomment it or reinsert it here if you are going to be using the
#   FRH as a CGI program.
    
CGIHandler::handleRequest();        # Entry point for execution as CGI Process
#return 1;                          # Return true, do nothing, when used as lib.
    
################################################################
#
# Package KXMF
#
# A platform-neutral package for constructing and sending KXMF
#   messages.
#
# This package should remain independent of any specific web page 
#   technology (e.g., CGI, ASP).  Fundamentally, it takes two kinds
#   of input, form message data and environment/configuration
#   settings, and it creates one kind of output, KXMF messages.
#
# Form message data is represented as an ordered list (array) of 
#   attributes (name-value pairs).  Form message data is typically
#   generated from a web browser submitting an HTML form, but in
#   principle the data can come from any source.  The order in the
#   attribute list is maintained as the default for all
#   presentations/views of the data.
#
# Environment/configuration information is represented as a hash of
#   property names and values.
#
# NOTE:  For efficiency, this package directly reads its input data
#   via the references it is given.  It does not create copies, but
#   it doesn't modify the data either.
#

package KXMF;

use MIME::Lite;


# Package variables
#
# $KXMF::defaultMailTo  - default recipient address
# $KXMF::defaultSubject - default message subject
# $KXMF::textTemplate   - formatted template for text body
# $KXMF::htmlTemplate   - formatted template for HTML body
# @KXMF::textFormat     - formatting parameters for text body
# @KXMF::htmlFormat     - formatting parameters for HTML body
# @KXMF::xmlFormat      - formatting parameters for XML body
# $KXMF::contentTransferEncoding - CTE to be used by MIME::Lite

# Initializes (or re-initializes) the package.
# Parameters:
#   - reference to a hash of environment/configuration settings
#
sub init($) {
    my $configHash = $_[0];

    $KXMF::defaultSubject = $configHash->{'Subject'};
    $KXMF::defaultMailTo = $configHash->{'MailToAddress'};
    if ($configHash->{'CCToAddress'}) {
        $KXMF::defaultCCTo = $configHash->{'CCToAddress'};
    } else {
        $KXMF::defaultCCTo = "no cc";
    }
    if ($configHash->{'MessageTextTemplate'}) {
        $KXMF::textTemplate = $configHash->{'MessageTextTemplate'};
    } else {
        @KXMF::textFormat = ($configHash->{'PlainTextPrologue'},
                                $configHash->{'PlainTextFormat'},
                                $configHash->{'PlainTextEpilogue'},);
    }
    
    if ($configHash->{'MessageHTMLTemplate'}) {
        $KXMF::htmlTemplate = $configHash->{'MessageHTMLTemplate'};
    } else {
        @KXMF::htmlFormat = ($configHash->{'HtmlTextPrologue'},
                                 $configHash->{'HtmlTextFormat'},
                                 $configHash->{'HtmlTextEpilogue'});
    }
    
    @KXMF::xmlFormat = (
            "<?xml version=\"1.0\" encoding=\"ISO-8859-1\" ?>\n<kanaRoot>\n  <kanaMessage>\n",
            "    <kanaAttribute name=\"\{0\}\">\{1\}</kanaAttribute>\n",
            "  </kanaMessage>\n</kanaRoot>",
    );

    
    #  Configure MIME::Lite's message sending parameters.
    # 
    eval {
            MIME::Lite->send('smtp',
                             $configHash->{'SmtpServer'},
                             Timeout=>60);
    };
    if ($@) {
            warn  "Could not configure MIME::Lite to send SMTP messages ($@)";
            throwKXMFException(
                "Message initialization failed.");
    }
}
     
# Builds a KXMF message.
# Parameters:
#   - reference to an array of attributes (name-value pairs)
# Optional:
#   - a reference to a hash containing a list of fields to ignore 
#    (these will not be included in the outgoing message at all)
#   - a reference to a hash containing a list of fields to hide from the CSR
#    (these will be included in the XML, but not in the HTML or text portions)
#   - a list of fields containing file attachments
# Returns:
#   - a MIME::Lite message object
#
sub buildKXMF($;$$$) {
    my $attributeArray = $_[0];
    my $ignoreHash = $_[1];        #  fields to ignore completely
    my $hiddenHash = $_[2];        #  fields to hide from CSR
    my $attachments = $_[3];    #  file attachments    
    my $haveAttachments = "no";
    if (scalar @$attachments > 0) {
        $haveAttachments = "yes";
    }

    my ($mailTo, $mailFrom, $mailSubject) = getHeaders($attributeArray);
    
    my $plainBody;
    my $htmlBody;
    my $xmlBody;
    ($plainBody, $htmlBody, $xmlBody) = generateBodies($attributeArray, $ignoreHash, $hiddenHash);
    
    my $msg;
    if ($haveAttachments eq "no") {
        # CASE: KXMF Message without attachnments

        $msg = MIME::Lite->new('To' => $mailTo,
                               'From' => $mailFrom,
                               'Subject' => $mailSubject,
                               'X-KanaMessageType' => 'FormMessage',
                               'Type' => 'multipart/alternative');
        if ($KXMF::defaultCCTo ne "no cc"){
            $msg->replace('Cc' => $KXMF::defaultCCTo);
        }

        $msg->attach('Type' => 'text/plain',
                     'Data' => $plainBody,
                     'Encoding' => $KXMF::contentTransferEncoding);
        $msg->attach('Type' => 'text/html',
                     'Data' => $htmlBody,
                     'Encoding' => $KXMF::contentTransferEncoding);
        $msg->attach('Type'=> 'text/xml',
                     'Data' => $xmlBody,
                     'Encoding' => $KXMF::contentTransferEncoding);
    } else {
        # CASE: KXMF Message with one or more attachnments

        $msg = MIME::Lite->new('To' => $mailTo,
                                  'From' => $mailFrom,
                                  'Subject' => $mailSubject,
                                  'X-KanaMessageType' => 'FormMessage',
                                  'Type' => 'multipart/mixed');
        if ($KXMF::defaultCCTo ne "no cc"){
            $msg->replace('Cc' => $KXMF::defaultCCTo);
        }

        my $bodies = $msg->attach('Type' => 'multipart/alternative');        

        $bodies->attach('Type' => 'text/plain',
                     'Data' => $plainBody,
                     'Encoding' => $KXMF::contentTransferEncoding);
        $bodies->attach('Type' => 'text/html',
                     'Data' => $htmlBody,
                     'Encoding' => $KXMF::contentTransferEncoding);
        $bodies->attach('Type'=> 'text/xml',
                     'Data' => $xmlBody,
                     'Encoding' => $KXMF::contentTransferEncoding);

        foreach my $attach_file (@$attachments) {
            my $name = $attach_file->[0];
            my $type = $attach_file->[1];
            my $file = $attach_file->[2];
            $msg->attach('Path' => $file,
                        'Disposition' => 'attachment',
                        'Filename' => $name,
                        'Encoding' => 'base64',
                        'Type' => $type
                        );
         }
    }

    return $msg;
}

# Generates the set of bodies for a KXMF message.
# Parameters:
#   - reference to an array of attributes (name-value pairs)
# Optional:
#   - a reference to a hash containing a list of fields to ignore 
#    (these will not be included in the outgoing message at all)
#   - a reference to a hash containing a list of fields to hide from the CSR
#    (these will be included in the XML, but not in the HTML or text portions)
# Returns:
#   - a list containing the three message bodies as strings
#
sub generateBodies($;$$) {
    my $attributeArray = $_[0];
    my $ignoreHash = $_[1];        #  fields to ignore completely
    my $hiddenHash = $_[2];        #  fields to hide from CSR
    my $plainBody;
    my $htmlBody;
    my $xmlBody;

    if ($KXMF::textTemplate) {
        $plainBody = RSTE::renderFile($KXMF::textTemplate, 0);
    } else {
        $plainBody = generateBody($attributeArray, \@KXMF::textFormat, 0, $hiddenHash);
    }

    if ($KXMF::htmlTemplate) {
        $htmlBody = RSTE::renderFile($KXMF::htmlTemplate, 1);
    } else {
        $htmlBody  = generateBody($attributeArray, \@KXMF::htmlFormat, 1, $hiddenHash);
    }
    
    $xmlBody = generateBody($attributeArray, \@KXMF::xmlFormat, 1, $ignoreHash);

    return ($plainBody, $htmlBody, $xmlBody);
}
     
# Returns a list of SMTP header values for 'To', 'From', and 'Subject'.
#
sub getHeaders($) {
    my $attributeArray = $_[0];

    my $emailAddress = "";
    my $firstName = "";
    my $lastName = "";
    my $fullName = "";
    
    my $mailTo = $KXMF::defaultMailTo;
    my $mailFrom = "";
    my $mailSubject = $KXMF::defaultSubject;
    
# KXMF policy:
#   - form data may NOT provide the recipient e-mail address
#   - form data must provide the sender's e-mail address
#   - form data may provide the message subject
# Scan the form data for sender and subject information.
# 
    my $nameValue;
    foreach $nameValue (@$attributeArray) {
            my $name = $nameValue->[0];
            my $value = $nameValue->[1];

            $name =~ tr/[A-Z]/[a-z]/;
    
            if ($name eq "email address" && $value !~ /^\s*$/) {
                $emailAddress = $value;
                next;
            }
            if ($name eq "first name" && $value !~ /^\s*$/) {
                $firstName = $value;
                next;
            }
            if ($name eq "last name" && $value !~ /^\s*$/) {
                $lastName = $value;
                next;
            }
            if ($name eq "full name" && $value !~ /^\s*$/) {
                $fullName = $value;
                next;
            }
            if ($name eq "subject" && $value !~ /^\s*$/) {
                $mailSubject = $value;
                next;
            }
    }
    
# Use the required e-mail address plus available name information
#   to compose the SMTP from header.
# 
    if (! $emailAddress) {
            throwKXMFException("Form data must include \"Email Address\" field.");
    } else {
        $CGIHandler::senderEmail = $emailAddress;
    }
    
    if ($firstName && $lastName) {
            $mailFrom = "$firstName $lastName <$emailAddress>";
    } elsif ($fullName) {
            $mailFrom = "$fullName <$emailAddress>";
    } else {
            $mailFrom = $emailAddress;
    }
    
# Return a list.
# 
    return ($mailTo, $mailFrom, $mailSubject);
}
    
    
# Generates a version of the message body.
# Parameters:
#   - reference to an array of attributes (name-value pairs)
#   - reference to a format array (prologue, name-value format, epilogue)
# Optional parameters:
#   - number (0/1) indicating whether or not to remap special HTML chars (&, <, >, ", ')
#   - reference to a hash of field names to exclude from body
# 
sub generateBody($$;$$) {
    my $attributeArray = $_[0];
    my $formatArray = $_[1];
    my $quoteHTML = $_[2];
    my $exclusionHash = $_[3];
    
    # replace missing formats with blanks
    $formatArray->[0] = "" if not $formatArray->[0];
    $formatArray->[1] = "" if not $formatArray->[1];
    $formatArray->[2] = "" if not $formatArray->[2];

# Apply the format to each of the name-value pairs,
#   unless the name is in the exclusion set.
# 
    my $formattedAttributes = "";
    my $nameValue;
    foreach $nameValue (@$attributeArray) {
            my $name = $nameValue->[0];
            my $value = $nameValue->[1];

        # replace missing values with blanks 
        $value = "" if not $value;

        my $lcName = $name;
        $lcName =~ tr/[A-Z]/[a-z]/;
    
        if ($exclusionHash && $exclusionHash->{$lcName}) {
            next;
        }
            
        if ($quoteHTML) { 
            $value =~ s/[\x01-\x08\x0B\x0C\x0E-\x1F]//g; # strip low control chars except NULL and whitespace
            $value =~ s/&/&amp;/g;
            $value =~ s/>/&gt;/g;
            $value =~ s/</&lt;/g;
            $value =~ s/\"/&quot;/g;
#             $value =~ s/\'/&apos;/g;  # included since \' is a special char in the XML spec, 
        }                               # but disabled b/c (A) \' in PCDATA doesn't kill IBM parser, 
                                        #                  (B) IE doesn't recognize &apos; in HTML
        
        
        my $nameValueText = $formatArray->[1];
        $nameValueText =~ s/\{0\}/$name/;
        $nameValueText =~ s/\{1\}/$value/;
    
        $formattedAttributes .= $nameValueText;
    }
    
    return $formatArray->[0] . $formattedAttributes . $formatArray->[2];
}
  
# Sends a message by SMTP.
# Parameters:
#   - a MIME::Lite message object
# 
sub send($) {
    my $msg = $_[0];
    
    # Trap any error from MIME::Lite in order to control
    # the error message.
    eval {
            $msg->send;
    };
    if ($@) {
        warn  "MIME::Lite error sending message: $@";
            throwKXMFException("Message send failed.");
    }
}
    
    
# Throws an exception by invoking die().
# Optional parameter:
#   - error message
# 
sub throwKXMFException(;$) {
    my $errorMessage = $_[0];
    warn $errorMessage;
    die "$errorMessage\n";
    }
    
    
################################################################
# 
# Package CGIHandler
# 
# A package for loading configuration properties and for sending
#   KXMF Messages; functions as a standalone CGI program via sub
#   handleRequest(), or as a library called from within another
#   Perl CGI program via sub sendFormMessage().   
# 
# 
    
package CGIHandler;    
 
# Package variables
# 
# %aliases                - hash of field name aliases
# %configuration          - configuration settings
# %fieldTypes             - hash of field type assignments
# %hiddenFields           - hash of fields not to send to CSR
# %ignoreFields           - hash of fields to ignore
# %mandatoryFields        - hash of mandatory fields
# %NoEchoFields           - hash of fields not to echo to user
# @readCookies            - list of cookies to be read by the CGI program
# @errorCookies           - list of cookie value rules to be set by the CGI program on an error
# @confirmationCookies    - list of cookie value rules to be set by the CGI program on a successful send
# @invalidCookies         - list of cookie value rules to be set by the CGI program in the case of validation failure
# @env_vars               - list of environment variables to insert
# @confirmationPageFormat - array of formatting parameters (used only if CGI)
# $confirmationRedirect   - URL of confirmation page, if it's external rather than generated
# $confirmationTemplate   - confirmation template filename
# $errorRedirect          - URL of error message page, if an external error message is available    
# $errorTemplate          - error template filename
# $invalidRedirect        - URL of invalid input response page, if it's external rather than generated
# $invalidTemplate        - invalid input response template filename
# $propertiesPath         - path to properties file(s)
# $propertiesFileName     - properties file name being used
# $messageLogPath         - path to message log file
# $messageLogFileName     - message log file name being used
# $senderEmail            - Form Submitter's email address.
# $sendFlag               - FRH mode flag: send or do not send.


# Handles a CGI request.
# 
sub handleRequest() {
    my $cgiQuery;           # CGI object
    my $attributeArray;     # reference to a list of attributes
    my $msg;                # message to send out
    my @attachments;        # list of attachments

    $cgiQuery = CGI->new();
    $CGIHandler::sendFlag = "yes";
    eval {
        loadCGIConfiguration($cgiQuery);
        @attachments = getAttachments($cgiQuery);
        $attributeArray = getFormData($cgiQuery);
        mapFieldNames($attributeArray);
        RSTE::initialize($attributeArray);
        if (validate($attributeArray) != 1) {
            sendValidationFailedResponse($cgiQuery);        
            closeAttachments(\@attachments);
        }

        if ($CGIHandler::sendFlag eq "yes") {
            KXMF::init(\%CGIHandler::configuration);
            $msg = KXMF::buildKXMF($attributeArray,  \%CGIHandler::ignoreFields, \%CGIHandler::hiddenFields, \@attachments);
            KXMF::send($msg);
        }

    };
    
    if ($@) {
            exitWithHtmlErrorPage($cgiQuery, $@);
            closeAttachments(\@attachments);
    }

    sendHtmlResponse($cgiQuery, $attributeArray);
    closeAttachments(\@attachments);
}    

# Handles a form passed by an outside CGI.
# Parameters:
#   - reference to an array of attributes (name-value pairs)
# Returns:
#   - 1 if successful, error string beginning with 0 if failed, -1 if invalid
#
# NOTE: Attachments, No Send, 
 
sub sendFormMessage($) {
    my $attributeArray = $_[0];            # reference to a list of attributes
    my $msg;                            #  message to send out
    $CGIHandler::sendFlag = "yes";
    eval {
        loadLibConfiguration($attributeArray);
        mapFieldNames($attributeArray);
        RSTE::initialize($attributeArray);
        if (validate($attributeArray) != 1) {
            return -1;        
        }
        KXMF::init(\%CGIHandler::configuration);
        $msg = KXMF::buildKXMF($attributeArray,  \%CGIHandler::ignoreFields, \%CGIHandler::hiddenFields);
        KXMF::send($msg);
    };

    if ($@) {
        warn  "Form submission failed: $@";
            return "0 $@";
    }

    return 1;
}

# Validates an incoming form against the set of mandatory and typed fields.
# Parameters:
#   - reference to an array of attributes (name-value pairs)
# Returns:
#   - 1 if successful, 0 if failed
#
sub validate($) {
    my $attributeArray = $_[0];
    my $nameValue;
    my $isValid = 1;
    my %fieldsHash;
    foreach $nameValue (@$attributeArray) {
        my $type;
        my $name = $nameValue->[0];
        $name =~ tr/[A-Z]/[a-z]/;
        my $value = $nameValue->[1];
        $fieldsHash{$name} = $value;       
    }
    
    my $name;
    foreach $name (keys %fieldsHash) {
        my $type;
        $name =~ tr/[A-Z]/[a-z]/;
        if ($type = $CGIHandler::fieldTypes{$name}) {
            my $value = $fieldsHash{$name};
            if (($value ne "") and ($value !~ /^\s*$/) and validateField($type, $value, \%fieldsHash) == 0) {
                $isValid = 0;
                RSTE::insertField("mismatched", $name);
            }
        }
    }
    
    my $field;
    foreach $field (keys %CGIHandler::mandatoryFields) {
        my $value;
        # if field is missing, blank, or contains only spaces, it fails to "mandatory" test
        if ((not defined ($value = $fieldsHash{$field})) or ($value eq "") or ($value =~ /^\s*$/)) {
           $isValid = 0;
           RSTE::insertField("missing", $CGIHandler::mandatoryFields{$field});
        }       
    }
    return $isValid;
}

# Validates an incoming form against the set of mandatory and typed fields.
# Parameters:
#   - field type to validate against or regexp
#   - field data
# Returns:
#   - 1 if successful, 0 if failed
#
sub validateField($$$) {
    my $type  = $_[0];
    my $value = $_[1];
    my $fieldsHash = $_[2];
    if ($type =~ m/^\s*match\((.+)\)/i) {
        my $tre = $1;
        $tre =~ tr/[A-Z]/[a-z]/;
        if ($value ne $fieldsHash->{$tre}) {
            return 0;
        } else {
            return 1;
        }
    }

    if ($type =~ m/^\s*matchi\((.+)\)/i) {
        my $tre = $1;
        $tre =~ tr/[A-Z]/[a-z]/;
        my $vali = $value;
        my $ovali = $fieldsHash->{$tre};
        $vali  =~ tr/[A-Z]/[a-z]/;
        $ovali =~ tr/[A-Z]/[a-z]/;
        
        if ($vali ne $ovali) {
            return 0;
        } else {
            return 1;
        }
    }

    if ($type =~ m/^\s*reg\((.+)\)/i) {
        my $tre = $1;
        if ($value !~ m/$tre/) {
            return 0;
        } else {
            return 1;
        }
    }


    if ($type =~ m/^\s*notreg\((.+)\)/i) {
        my $tre = $1;
        if ($value =~ m/$tre/) {
            return 0;
        } else {
            return 1;
        }
    }

    if ($type =~ m/^\s*eq\((.+)\)/i) {
        my $tre = $1;
        if ($value eq $tre) {
            return 1;
        } else {
            return 0;
        }
    }

    if ($type =~ m/^\s*neq\((.+)\)/i) {
        my $tre = $1;
        if ($value ne $tre) {
            return 1;
        } else {
            return 0;
        }
    }

    if ($type =~ m/^\s*regi\((.+)\)/i) {
        my $tre = $1;
        if ($value !~ m/$tre/i) {
            return 0;
        } else {
            return 1;
        }
    }

    if ($type =~ m/^\s*notregi\((.+)\)/i) {
        my $tre = $1;
        if ($value =~ m/$tre/i) {
            return 0;
        } else {
            return 1;
        }
    }

    if ($type =~ m/^\s*eqi\((.+)\)/i) {
        my $tre = $1;
        my $newval = $value;
        $tre =~ tr/[A-Z]/[a-z]/;
        $newval =~ tr/[A-Z]/[a-z]/;
        if ($newval eq $tre) {
            return 1;
        } else {
            return 0;
        }
    }

    if ($type =~ m/^\s*neqi\((.+)\)/i) {
        my $tre = $1;
        my $newval = $value;
        $tre =~ tr/[A-Z]/[a-z]/;
        $newval =~ tr/[A-Z]/[a-z]/;
        if ($newval ne $tre) {
            return 1;
        } else {
            return 0;
        }
    }


    if ($type =~ /^\s*stringlen\((\d*):(\d*)\)/i) {
        my $minlen;
        if (not $1) { $minlen = 0; } else { $minlen = $1; }
        my $maxlen;
        if (not $2) { $maxlen = 255; } else { $maxlen = $2; }
        if ((length($value) < $minlen) or (length($value) > $maxlen)) {
            return 0;
        } else {
            return 1;
        }
    }

    if ($type =~ /^\s*minmax\((\d*):(\d*)\)/i) {
        my $min = $1;
        if (not $1) { $min = 0; } else { $min = $1; }
        my $max = $2;
        if (not $2) { $max = 255; } else { $max = $2; }
        if ($value !~ m/^\s*[+|-]?\s?\d+(\.\d+)?\s*$/ or ($value < $min) or ($value > $max)) {
            return 0;
        } else {
            return 1;
        }
    }

    if ($type =~ /^\s*min\((\d*)\)/i) {
        my $min = $1;
        if (not $1) { $min = 0; } else { $min = $1; }
        if ($value !~ m/^\s*[+|-]?\s?\d+(\.\d+)?\s*$/ or ($value < $min)) {
            return 0;
        } else {
            return 1;
        }
    }
    if ($type =~ /^\s*max\((\d*)\)/i) {
        my $max = $1;
        if (not $2) { $max = 255; } else { $max = $2; }
        if ($value !~ m/^\s*[+|-]?\s?\d+(\.\d+)?\s*$/ or ($value > $max)) {
            return 0;
        } else {
            return 1;
        }
    }
   
    if (($type =~ /^\s*numeric/i) or ($type =~ /^\s*decimal/i) or ($type =~ /^\s*float/i)) {
        if ($value !~ m/^\s*[+|-]?\s?\d+(\.\d+)?\s*$/) {
            return 0;
        } else {
            return 1;
        }
    }

    if ($type =~ /^\s*integer/i) {
        if ($value !~ m/^\s*[+|-]?\s?\d+\s*$/) {
            return 0;
        } else {
            return 1;
        }
    }

    warn "Invalid type '$type'\n";
    return 1;
}
        
# CGI Specific/Prepares to load a new set of configuration 
#   properties into %configuration.
# Parameters:
#   - CGI object containing the form data
# 
sub loadCGIConfiguration($) {
    my $cgiQuery = $_[0];
    
    my $propertiesFile = $cgiQuery->param('frh.properties');
    if ($propertiesFile) { 
            $cgiQuery->delete('frh.properties'); 
    }

    my $mySendFlag = $cgiQuery->param('frh.send');
    $mySendFlag =~ tr/[A-Z]/[a-z]/ if $mySendFlag;
    if ($mySendFlag && $mySendFlag eq "no") { 
            $CGIHandler::sendFlag = $mySendFlag;
            $cgiQuery->delete('frh.send'); 
    }

    my $template = $cgiQuery->param('frh.template');
    if ($template) { 
            $CGIHandler::confirmationTemplate = $template;
            $cgiQuery->delete('frh.template'); 
    }

    loadConfiguration($propertiesFile);
}
    
# Library Specific/Prepares to load a new set of configuration 
#   properties into %configuration.
# Parameters:
#   - reference to an array of attributes (name-value pairs)
# 
sub loadLibConfiguration($) {
    my $attributeArray = $_[0];
    my $propertiesFile;
    my $nameValue;
    my $scan;
    
    for ($scan = 0; $scan < scalar(@$attributeArray); $scan++) { 
            $nameValue = @$attributeArray[$scan];
            if ($nameValue->[0] eq "frh.properties") {
                $propertiesFile = $nameValue->[1];
                splice(@$attributeArray, $scan, 1);
                last;
            }
    }
     
    loadConfiguration($propertiesFile);
}
    
# Finishes loading a new set of configuration properties into 
#   %configuration. (called by loadLibConfiguration() or
#   loadCGIConfiguration())
# Parameters:
#   - filename of configuration/properties file
# 
sub loadConfiguration($) {
    my $propertiesFile = $_[0];
    %CGIHandler::configuration = ();  
    $propertiesFile = fixPropertiesFileName($propertiesFile);
    
    loadRawProperties($propertiesFile);
    
# Derive further information from the raw property values.
# 
    setAttachFields();
    setAliases();
    setTypes();
    setCookieLists();
    setIgnoreFields();
    setHiddenFields();
    setNoEchoFields();
    setMandatoryFields();
    setResponseFormats();
    setEnvVars();
    ensureDefaultSubject();
    checkSendFlag();
    setLogFilename();
    }
    
# Loads a set of raw configuration properties into %configuration.
# Parameters:
#   - filename and path to configuration/properties file
# 
# The current implementation reads the preference data from a file
#   using the Java properties file format:  
#   - a leading '#' means the line is a comment
#   - a backslash at the end of a line continues the value onto
#     the next line
# 
sub loadRawProperties($) {
    my $precedingLine = "";
    my $propertiesFile = $_[0];
    
# Open and read from the preferences file.
# 
    open(PREFERENCES, $propertiesFile) 
            || throwCGIHandlerException(
                    "Cannot open properties file ($propertiesFile).");
    while(<PREFERENCES>) {
            chomp;
    
            # Skip comment lines.
            # If the line ends with a backslash,
            #   delete the backslash (and any following CR or LF),
            #   then save the string to be continued on the next input line.
            #
            if (/^\s*#/) {
                next;
            }
            if (s/\\[\n\r]*$//) {
                $precedingLine .= $_;
                next;
            }
    
            # If input is continued from preceding line(s),
            #   prepend (and consume) the preceding material.
            #
            if ($precedingLine) {
                $_ = $precedingLine . $_;
                $precedingLine = "";
            }
                     
            # Parse the property name and value and add them to the
            #   preferences data.
            #
            if (/^\s*(.*?)\s*=\s*(.*?)\s*$/) {
                my $name = $1;   # text matched by first parens
                my $value = $2;  # text matched by second parens
                $value =~ s/\\n/\n/g;
                $CGIHandler::configuration{$name} = $value;
            }
    }
    
    close(PREFERENCES);
    }
    
    
# Determines the real location of the properties information.
# Parameters:
#   - filename of configuration/properties file
# Returns: 
#   - filename and path to configuration/properties file
# 
# This bootstrap function can peek at form data but can only do
#   so in a way that doesn't rely on any properties information.
# 
sub fixPropertiesFileName($) {
    my $propertiesDir = "./";
    my $propertiesName;
    my $serverSoftware;
    
    if ($_[0]) { 
        $propertiesName = $_[0];
    } else {
        $propertiesName = "frh.properties";
    }
   
    $CGIHandler::propertiesFileName = $propertiesName;
    
    # If the properties file name contains an illegal character, throw an exception
    #
    if ($propertiesName =~ /[\/\\<>\?\*:\"\|]/) {
        throwCGIHandlerException("Illegal properties file name: '$propertiesName' contains an illegal character");        
    }
    
    if ($CGIHandler::propertiesPath) {
        $propertiesDir = $CGIHandler::propertiesPath;
    } 
        
    return($propertiesDir . $propertiesName);
}
    
   
# Creates an Attachment field set from the configuration data.
#
sub setAttachFields() {
    %CGIHandler::attachFields = ();
    my $attachString;
    if ($attachString = $CGIHandler::configuration{'AttachFields'}) {
      my $fieldName;
      foreach $fieldName (split(/\s*,\s*/, $attachString)) {
          if ($fieldName) {
              $CGIHandler::attachFields{$fieldName} = 1;
          }
      }
    }
}


# Creates a new aliases hash from the configuration data.
# 
sub setAliases() {
    %CGIHandler::aliases = ();
    
    my $aliasString;
    if ($aliasString = $CGIHandler::configuration{'Aliases'}) {
            my $nameAlias;
            foreach $nameAlias (split(/\s*,\s*/, $aliasString)) {
    
            # Process only items that look like name => alias.
            # Remove any white space surrounding names and values.
            # 
                if ($nameAlias =~ /^(.*?)\s*=>\s*(.*)$/) {
                my $formName = $1;
                my $kanaName = $2;
                $formName =~ tr/[A-Z]/[a-z]/;
                $CGIHandler::aliases{$formName} = $kanaName;
                }
            }
    }
}

# Creates a new Types hash from the configuration data.
# 
sub setTypes() {
    %CGIHandler::fieldTypes = ();
    
    my $typeString;
    if ($typeString = $CGIHandler::configuration{'Types'}) {
            my $nameType;
            my $prevType = '$$$';
            foreach $nameType (split(/,\s*/, $typeString)) {
                if ($prevType ne '$$$') {
                    $nameType = $prevType . ',' . $nameType;
                    $prevType = '$$$';
                }
                if ($nameType =~ /\\$/) {
                    $prevType = $`;
                } else {    
                # Process only items that look like name => type.
                # Remove any white space surrounding names and values.
                # 
                    if ($nameType =~ /^(.*?)\s*=>\s*(.*)$/) {
                    my $formName = $1;
                    my $type = $2;
                    $type =~ s/\\,/,/g;
                    $formName =~ tr/[A-Z]/[a-z]/;
                    $CGIHandler::fieldTypes{$formName} = $type;
                    }
                }
            }
    }
}

# Create a new Cookies arrays from the configuration data.
# 
sub setCookieLists() {
    @CGIHandler::errorCookies = ();
    setCookieSet(\@CGIHandler::errorCookies, "ErrorPageCookies");
    @CGIHandler::confirmationCookies = ();
    setCookieSet(\@CGIHandler::confirmationCookies, "ConfirmationPageCookies");
    @CGIHandler::invalidCookies = ();
    setCookieSet(\@CGIHandler::invalidCookies, "ValidationFailedCookies");
    @CGIHandler::setCookies = ();
    @CGIHandler::readCookies = ();    
    
    my $rcString;
    if ($rcString = $CGIHandler::configuration{'CookieFields'}) {
            my $fieldName;
            foreach $fieldName (split(/\s*,\s*/, $rcString)) {
                if ($fieldName) {
                    push (@CGIHandler::readCookies, $fieldName);
                }
            }
    }
}

# Create a new Cookies arrays from the configuration data.
# 
sub setCookieSet($$) {
    my $cookieset = $_[0];
    my $propertyName = $_[1];
    
    my $cookieString;
    if ($cookieString = $CGIHandler::configuration{$propertyName}) {
            my $nameValue;
            foreach $nameValue (split(/\s*,\s*/, $cookieString)) {
    
            # Process only items that look like name => type.
            # Remove any white space surrounding names and values.
            # 
                if ($nameValue =~ /^(.*?)\s*=>\s*(.*):(.*):(.*)$/) {
                    my $name = $1;
                    my $domain = $2;
                    my $exp = $3;
                    my $value = $4;
                    push(@$cookieset, [$name, $domain, $exp, $value]);            
                }
            }
    }
}


# Creates a new Ignore set from the configuration data.
# 
sub setMandatoryFields() {
    %CGIHandler::mandatoryFields = ();
    
    my $mandatoryString;
    if ($mandatoryString = $CGIHandler::configuration{'MandatoryFields'}) {
        my $fieldName;
        foreach $fieldName (split(/\s*,\s*/, $mandatoryString)) {
            if ($fieldName) {
                my $lcName = $fieldName;
                $lcName =~ tr/[A-Z]/[a-z]/;
                $CGIHandler::mandatoryFields{$lcName} = $fieldName;
            }
        }
    }
}
    
# Creates a new Ignore set from the configuration data.
# 
sub setIgnoreFields() {
    %CGIHandler::ignoreFields = ();
    
    my $ignoreString;
    if ($ignoreString = $CGIHandler::configuration{'Ignore'}) {
        my $fieldName;
        foreach $fieldName (split(/\s*,\s*/, $ignoreString)) {
            if ($fieldName) {
                $fieldName =~ tr/[A-Z]/[a-z]/;
                $CGIHandler::ignoreFields{$fieldName} = 1;
            }
        }
    }
}
    
# Creates a new Hide set from the configuration data.
# 
sub setHiddenFields() {
    %CGIHandler::hiddenFields = ();
   
    my $hideString;
    if ($hideString = $CGIHandler::configuration{'Hide'}) {
        my $fieldName;
        foreach $fieldName (split(/\s*,\s*/, $hideString)) {
            if ($fieldName) {
                $fieldName =~ tr/[A-Z]/[a-z]/;
                $CGIHandler::hiddenFields{$fieldName} = 1;
            }
        }
    }
    
    foreach $hideString (keys %CGIHandler::ignoreFields) {
        $CGIHandler::hiddenFields{$hideString} = 1;
    }
}
    
# Creates a new NoEcho set from the configuration data.
# 
sub setNoEchoFields() {
    %CGIHandler::NoEchoFields = ();
    
    my $noechoString;
    if ($noechoString = $CGIHandler::configuration{'NoEcho'}) {
        my $fieldName;
        foreach $fieldName (split(/\s*,\s*/, $noechoString)) {
            if ($fieldName) {
                $fieldName =~ tr/[A-Z]/[a-z]/;
                $CGIHandler::NoEchoFields{$fieldName} = 1;
            }
        }
    }
    foreach $noechoString (keys %CGIHandler::ignoreFields) {
        $CGIHandler::NoEchoFields{$noechoString} = 1;
    }
    
    foreach $noechoString (keys %CGIHandler::hiddenFields) {
        $CGIHandler::NoEchoFields{$noechoString} = 1;
    }
}
    
# Sets the confirmation page format, as well as redirects and templates, 
# if any, from the configuration data.
# 
sub setResponseFormats() {
    my $confirmationTemplate;
    my $confirmationRedirect;
    my $errorTemplate;
    my $errorRedirect;
    my $invalidTemplate;
    my $invalidRedirect;
    if ($confirmationTemplate = $CGIHandler::configuration{'ConfirmationPageTemplate'}) {
        $CGIHandler::confirmationTemplate = $confirmationTemplate;
    }
    if ($confirmationRedirect = $CGIHandler::configuration{'ConfirmationPageURL'}) {
        $CGIHandler::confirmationRedirect = $confirmationRedirect;
    }
    if ($errorTemplate = $CGIHandler::configuration{'ErrorPageTemplate'}) {
        $CGIHandler::errorTemplate = $errorTemplate;
    }
    if ($errorRedirect = $CGIHandler::configuration{'ErrorPageURL'}) {
        $CGIHandler::errorRedirect = $errorRedirect;
    }
    if ($invalidTemplate = $CGIHandler::configuration{'ValidationFailedTemplate'}) {
        $CGIHandler::invalidTemplate = $invalidTemplate;
    }
    if ($invalidRedirect = $CGIHandler::configuration{'ValidationFailedURL'}) {
        $CGIHandler::invalidRedirect = $invalidRedirect;
    }
    @CGIHandler::confirmationPageFormat = (
        $CGIHandler::configuration{'HtmlPagePrologue'},
        $CGIHandler::configuration{'HtmlPageFormat'},
        $CGIHandler::configuration{'HtmlPageEpilogue'}
    );
}

# Creates a new Environment Variable list from the configuration data.
# 
sub setEnvVars() {
    @CGIHandler::env_vars = ();
    
    my $envString;
    if ($envString = $CGIHandler::configuration{'EnvironmentFields'}) {
            my $fieldName;
            foreach $fieldName (split(/\s*,\s*/, $envString)) {
                if ($fieldName) {
                    push (@CGIHandler::env_vars, $fieldName);
                }
            }
    }
}
    
    
# $CGIHandler::messageLogPath         - path to message log file
# $CGIHandler::messageLogFileName     - message log file name being used

# Sets the Message Log Filename.
# 
sub setLogFilename() {
    my $logfilename;
    if ($logfilename = $CGIHandler::configuration{'LogFileName'}) {        

        # If the log file name contains an illegal character, log a warning and do not set the filename
        if ($logfilename =~ /[\/\\<>\?\*:\"\|]/) {
            warn("Illegal log file name: '$logfilename' contains an illegal character");        
            return;
        }

        $CGIHandler::messageLogFileName = $logfilename;
    }
}

# Checks for a "Send" flag in the properties file.
# 
sub checkSendFlag() {
    my $mySendFlag = $CGIHandler::configuration{'Send'};
    $mySendFlag =~ tr/[A-Z]/[a-z]/ if $mySendFlag;
    if ($mySendFlag && $mySendFlag eq "no") { 
            $CGIHandler::sendFlag = $mySendFlag;
    }
}


# Ensures that the configuration preferences contain a default message
#   subject.
# 
sub ensureDefaultSubject() { 
# If subject already exists, nothing more needed.
# 
    if ($CGIHandler::configuration{'Subject'}) {
            return;
    }
    
# The default subject attempts to indicate the source of the form.
# 
    my $fromWhere = "";
    if ($fromWhere = $ENV{'HTTP_REFERER'}) {
            $fromWhere = " from " . $fromWhere;
    } elsif ($fromWhere = $ENV{'SCRIPT_NAME'}) {
            $fromWhere = " via " . $fromWhere;
    } else {
            $fromWhere = "";
    }
    
    $CGIHandler::configuration{'Subject'} = "Form message" . $fromWhere;
}
    
# Builds a new array of name-value pairs representing the form data.
# Parameters:
#   - CGI object containing the form data
# Optional parameter:
#   - reference to an aliasing function, which can map form
#     field names to Kana-internal field names
# Returns:
#   - reference to an array of attributes (name-value pairs)
# 
sub getFormData($) {
    my $cgiQuery = $_[0];
    my @attributes = ();
    
    my $name;
    my $value;
            
    foreach $name ($cgiQuery->param()) {
            $value = $cgiQuery->param($name); 
            $value =~ s/\r//g if $value;                # strips CRs, leave LF
            push(@attributes, [$name, $value]);
    }
    
    # add environment variables, if they're found
    foreach $name (@CGIHandler::env_vars) {
        if ($value = $ENV{$name}) {
            push(@attributes, [$name, $value]);
            }
        }

    # add cookie fields, if they're found
    foreach $name (@CGIHandler::readCookies) {
        if ($value = $cgiQuery->cookie($name)) {
            push(@attributes, [$name, $value]);
            }
        }

        
    return \@attributes;
}
    
# Maps from raw form data name-value pairs to names suitable for the
#   Kana system.
# Parameters:
#   - reference to an array of attributes (name-value pairs)
# NOTE:  This function modifies the referred-to array in place.
# NOTE:  You cannot replace an attribute using an alias, unless
#        the value of that attribute is blank.
# 
sub mapFieldNames($) {
    my $attributeArray = $_[0];
    my %dupeChecker;
    my $nameValue;
    foreach $nameValue (@$attributeArray) {
        my $kanaName;
        my $formName = $nameValue->[0];
        $formName =~ tr/[A-Z]/[a-z]/;
        if (not $dupeChecker{$formName} or $dupeChecker{formName} =~ /^\s*$/) {
            $dupeChecker{$formName} = $nameValue->[1];
        }
        if ($kanaName = $CGIHandler::aliases{$formName}) {
            $formName = $kanaName;
            $formName =~ tr/[A-Z]/[a-z]/;
            if (not $dupeChecker{$formName} or $dupeChecker{$formName} =~ /^\s*$/) {
                $nameValue->[0] = $kanaName;
                $dupeChecker{$formName} = $nameValue->[1];
            } else {
                warn "Attempted duplicate alias '$kanaName' from '$nameValue->[0]'";
            }
        }
    }
}
    

# Processes incoming attachments.
# Checks each "AttachField" to see if it corresponds to an uploaded file, and if so,
# adds the attachment to the incoming message.
# Parameters:
#   - CGI object
# 
sub getAttachments($) {
    my $query = $_[0];
    my @attachments;
    my $attachField;
    foreach $attachField (keys %CGIHandler::attachFields) {
        my $filename;
        if ($filename = $query->upload($attachField)) {
            my $file = $query->tmpFileName($filename);
            # my $type = $query->uploadInfo($filename)->{'Content-type'};
            my $type = "application/octet-stream";
            if (-s $filename) {
                push(@attachments, [$filename, $type, $file]);
            } else { 
                close $filename;
            }
        }
        $query->delete($attachField);
    }
    return @attachments;
}

# Close attachment temporary files so they can be deleted.
# # Parameters:
#   - reference to the attachment list
# 
sub closeAttachments($) {
    my $attachments = $_[0];
    if (scalar @$attachments > 0) {
        foreach my $attach_file (@$attachments) {
            my $name = $attach_file->[0];
            close $name;    
        }
    }
}
    
    
# Creates the list of cookies to be set
# Parameters:
#   - CGI object
#   - reference to an array of cookie values (cookie name, domain, expiration, and value)
# 
sub createCookies($$) {
    my $cgiQuery = $_[0];
    my $cookieSet = $_[1];
    my $cookieBlob;
    foreach $cookieBlob (@$cookieSet) {
        my $name = $cookieBlob->[0];
        my $domain = $cookieBlob->[1];
        my $exp  = $cookieBlob->[2];
        my $value = $cookieBlob->[3];
        my $cookie;
        $value = RSTE::renderString($value,0);
        if (not $exp or $exp eq "" or $exp =~ /^\s*$/) {
            warn "No Expiration\n";
            if ($domain and $domain ne "" or $domain !~ /^\s*$/) {
                $cookie = $cgiQuery->cookie(-name => $name, -domain => $domain, -value => $value);
            } else {
                warn "No Domain\n";
                $cookie = $cgiQuery->cookie(-name => $name, -value => $value);
            }
        } else {
            if ($domain and $domain ne "" or $domain !~ /^\s*$/) {
                $cookie = $cgiQuery->cookie(-name => $name, -domain => $domain, -expires => $exp, -value => $value);
            } else {
                $cookie = $cgiQuery->cookie(-name => $name, -expires => $exp, -value => $value);
            }
        }
        push (@CGIHandler::setCookies, $cookie);
    }
}    
    
# Creates and sends an HTML confirmation page showing what data
#   was submitted in the web form (subject to NoEcho filtering if the default iterator is used).
# Parameters:
#   - CGI object for responses
#   - reference to an array of name-value pairs
# 
sub sendHtmlResponse($$) {
    my $cgiQuery = $_[0];
    createCookies($cgiQuery, \@CGIHandler::confirmationCookies);

    if ($CGIHandler::sendFlag eq "yes") {
        logRequest("Sent");
    } else {
        logRequest("Unsent.");
    }    

    my $attributeArray = $_[1];
    if ($CGIHandler::confirmationTemplate) {
        print $cgiQuery->header(-cookie => \@CGIHandler::setCookies );
        print RSTE::renderFile($CGIHandler::confirmationTemplate, 1);
    } elsif ($CGIHandler::confirmationRedirect) {
        my $redirect = $CGIHandler::confirmationRedirect;
        $redirect = RSTE::renderString($redirect, 2);
        print $cgiQuery->redirect(-uri=>$redirect, -cookie => @CGIHandler::setCookies);
    } else {    
        print $cgiQuery->header(-cookie=>@CGIHandler::setCookies);
        print KXMF::generateBody($attributeArray,
                                     \@CGIHandler::confirmationPageFormat,
                                     1,
                                     \%CGIHandler::NoEchoFields);
    }
}

# Generates an HTML error page and exits the program.
# Parameters:
#   - CGI object
# 
sub sendValidationFailedResponse($) {
    my $cgiQuery = $_[0];
    createCookies($cgiQuery, \@CGIHandler::invalidCookies);
    logRequest("Invalid");
    if ($CGIHandler::invalidTemplate) {
        print $cgiQuery->header(-cookie=>@CGIHandler::setCookies);
        print RSTE::renderFile($CGIHandler::invalidTemplate, 1);
    } elsif ($CGIHandler::invalidRedirect) {
        my $redirect = RSTE::renderString($CGIHandler::invalidRedirect,2);
        print $cgiQuery->redirect(-uri=>$redirect, -cookie=>@CGIHandler::setCookies);
    } else { 
        print $cgiQuery->header(-cookie=>@CGIHandler::setCookies);
        my $defaultTemplate = '<html><head><title>Form Validation Failed.</title></head>'."\n".
                              '<body><h2>Form Validation Failed</h2><B>Your form could not be submitted,'."\n".
                              'as it has missing required fields or has fields containing the wrong type'."\n".
                              ' of data.</B><BR>The following required fields were missing:<BR>'."\n".
                              '${@missing}"${Field Name}"<BR>${@end}<BR>'."\n".
                              'The following fields contain the wrong type of data:<BR>'."".
                              '${@mismatched}"${Field Name}"<BR>${@end}<BR>'."\n".
                              '<B>Please hit "Back" in your browser if you wish to correct the field(s).</B>'."\n".
                              '<BR></body></html>'."\n";
        print RSTE::renderString($defaultTemplate,1,"no");  
    }    
    exit;
}

# Generates an HTML error page and exits the program.
# Parameters:
#   - CGI object
#   - Error message
# 
sub exitWithHtmlErrorPage($;$) {
    my $cgiQuery = $_[0];
    my $errorMessage = $_[1];
    RSTE::insertPair("Error Message", $errorMessage);
    createCookies($cgiQuery, \@CGIHandler::errorCookies);
    logRequest("Error");
    if ($CGIHandler::errorTemplate) {
        print $cgiQuery->header(-cookie=>@CGIHandler::setCookies);
        print RSTE::renderFile($CGIHandler::errorTemplate, 1);
    } elsif ($CGIHandler::errorRedirect) {
        my $redirect = RSTE::renderString($CGIHandler::errorRedirect,2);
        print $cgiQuery->redirect(-uri=>$redirect, -cookie=>@CGIHandler::setCookies);
    } else { 
        print $cgiQuery->header(-cookie=>@CGIHandler::setCookies);
        print <<END_OF_INPUT;
<html>
<head>
<title>Web Form Error</title>
</head>
<body>
<h2>Web Form Error</h2>
<B>Your form could not be submitted, because an error has occurred:</B><BR>
<I>$errorMessage</I><BR>
</body>
</html>
END_OF_INPUT
    }    
    exit;
}

# Logs a message submission or other form request
#
sub logRequest($) {
    if (not $CGIHandler::messageLogFileName) { 
        return;
    }
    my $disposition = $_[0];    
    $disposition = "n/a" if not $disposition;

    my $referrer = $ENV{'HTTP_REFERER'};
    $referrer = "n/a" if not $referrer;

    my $email = $CGIHandler::senderEmail;
    $email = "n/a" if not $email;
    
    my $datetime = localtime;
    
    eval {
        open (MSGLOG, ">>".$CGIHandler::messageLogPath.$CGIHandler::messageLogFileName) or
            die("Unable to open FRH error log: $!\n");
        print MSGLOG "$datetime, $CGIHandler::propertiesFileName, $referrer, $email, $disposition\n";
        close MSGLOG;
    };
    if ($@) {
            warn("Message Logging Error: $@");
    }

}
    
# Throws a (usually) fatal exception by invoking die().
# Optional parameter:
#   - error message
#
sub throwCGIHandlerException(;$) {
    my $errorMessage = $_[0];
    warn  $errorMessage;    
    die "$errorMessage\n";
    }

################################################################
#
# Package RSTE
#
# "Really Simple Template Engine"
# This package renders (inserts values into) templates.
#  
# Name-value pairs in the standard attribute array format are received
#   by initialize; these values can then be rendered by renderFile 
#   or renderString, and sent as messages or returned as a confirmation page.
#
# Name-value pairs are represented internally a hash, which is initialized 
# once from a reference to the attribute array.

# Package variables
#
# %RSTE::values     - field values
# %RSTE::realnames  - field names (conserving case)
# %RSTE::marks      - field marks
# %RSTE::missing    - set of missing fields
# %RSTE::mismatch   - set of mismatched fields
# $RSTE::iterName   - field name for iterator

package RSTE;

# Loads the internal hash of values from a reference to an array of
#   name/value pairs.
# Parameters:
#   - reference to an array of attributes (name-value pairs)
# 
sub initialize($) {
    my $attributeArray = $_[0];
    my $nameValue;
    my $count = 0;
    foreach $nameValue (@$attributeArray) {
        my $name = $nameValue->[0];
        my $real = $name;
        $name =~ tr/[A-Z]/[a-z]/;
        my $value = $nameValue->[1];
        $RSTE::values{$name} = $value;
        $RSTE::realnames{$name} = $real;
        $RSTE::marks{$name} = "no";
    }
}

# Unmarks all fields.
sub unmarkall() {
    foreach my $name (keys %RSTE::marks) {
        $RSTE::marks{$name} = "no";
    }
}

# Inserts a name/value pair into the internal hash of values
# Parameters:
#   - name
#   - value
# 
sub insertPair($$) {
    my $name = $_[0];
    
    my $real = $name;
    my $value = $_[1];
    
    $name =~ tr/[A-Z]/[a-z]/;
    $RSTE::values{$name} = $value;
    $RSTE::realnames{$name} = $real;
    $RSTE::marks{$name} = "no";
}

# Insert a field in a hash of fields.
# Parameter:
#   - set to insert into
#   - field to insert
#
sub insertField($$) {
    my $set = $_[0];
    my $field = $_[1];
    my $hashSet;
    $set =~ tr/[A-Z]/[a-z]/;
    $field =~ tr/[A-Z]/[a-z]/;

    if ($set eq "missing") {
        $hashSet = \%RSTE::missing;
    } elsif ($set eq "mismatched") {
        $hashSet = \%RSTE::mismatch;
    } else { 
        return 
    }   
    
    # we can add more sets here.
    $hashSet->{$field} = $RSTE::realnames{$field};
}

# Renders a template file, by replacing ${a|b} references with values{a} or "b".
# Unmarks all marked fields.
#
# Parameters:
#   - a string containing the file name of the template to render
# Optional parameters:
#   - number (0/1/2) indicating whether or not to remap chars
#     and if so whether to remap HTML/XML (&, <, >, ", ') or to URLencode
# Returns:
#   - a string containing the rendered text
# 
sub renderFile($;$) {
    my $FileName = $_[0];
    $FileName = CGIHandler::fixPropertiesFileName($FileName);
    my $quote  =  $_[1];
    my $input = "";
    my $output = "";
    open(FILE, $FileName) 
                || throwRSTEException(
                            "Cannot open template file ($FileName).");
    while (<FILE>) {
        my $line; 
        $input .= $_;
    }
    close FILE;
    unmarkall();
    $output .= renderString($input, $quote) . "\n";
    return $output;
}

# *DEPRECATED* 
# (use renderString instead)
#
# Renders one line of template text, by replacing ${a|b} references 
#   with values{a} or "b".
sub renderLine($;$) {
    warn "Calling deprecated function 'renderLine'";
    renderString($_);
}

# Renders a string (possibly containing newlines) of template text to
#   the final form, by replacing ${a|b} references with values{a} or "b".
# Parameters:
#   - a string containing the template text
# Optional parameters:
#   - number (0/1/2) indicating whether or not to remap chars
#     and if so whether to remap HTML/XML (&, <, >, ", ') or to URLencode
# Returns:
#   - a string containing the rendered text
# 
sub renderString($;$$) {
    my $line = $_[0];
    my $quote = $_[1];
    my $line_out = "";
    my $iterating = $_[2];
    if (not $iterating) {
        $iterating = "no";
    }
    while ($line =~ /\${([\@\'\/\!\?\~^]?)([^{}]*)}/) {
        $line_out .= $`;
        $line = $';
        my $command = $1;
        my $fieldText = $2;
        my $altText;
        my $useAltText = 0;
        my $t_out = "";

        if ($fieldText =~ /\|/) {
            $useAltText = 1;
            $altText = "";
        }
        
        ($fieldText, $altText) = split /\|/, $fieldText, 2;
        
        $fieldText =~ tr/[A-Z]/[a-z]/;
        if ($fieldText !~ /^[a-z]([a-z0-9-_\s]*[a-z0-9])?$/) {
            warn "Template Field '$fieldText' is not a valid custom field or field set name.";
            }
        if ($altText && $altText =~ /\|/) {
            warn "Alt. Text '$altText' contains |(pipe char); truncating.";
            ($altText, my $null) = split /\|/, $altText, 2;
            }
        
        if ($iterating eq "yes") {
            if ($fieldText eq "field value") {  
                $fieldText = $RSTE::iterName;    
            }

            if ($fieldText eq "field name") {  
                $fieldText = "kana frh iterator internal field name";    
            }    
        } 

        # CASE 1: Regular insertion.
        if (not $command or $command eq "") {            
            if ($iterating eq "yes" and $fieldText eq "kana frh iterator internal field name") {
                $t_out = $RSTE::realnames{$RSTE::iterName};
                $t_out = $RSTE::iterName if not $t_out;
            } elsif ($RSTE::values{$fieldText}) {
                $t_out = $RSTE::values{$fieldText};
                $RSTE::marks{$fieldText} = "yes";
            } elsif ($useAltText == 1) { 
                $t_out = $altText; 
                $RSTE::marks{$fieldText} = "yes";
            } else {
                warn "Field '$fieldText' does not exist on this form.";
            }
                    
            if (defined $quote and $quote and $quote != 0) {
                if ($quote == 1) {
                    $line_out .= quoteStringHTML($t_out);   
                } elsif ($quote == 2) {
                    $line_out .= quoteStringURL($t_out);   
                } 
            } else {
                $line_out .= $t_out;
            }
        } 
        
        # CASE 2: Iterator Block Start (should never find iterator block end)
        elsif ($command eq "@") {
            my $set = "";
            if ($iterating eq "yes") {
                warn "Iterator start while iterating makes no sense! (no recursive iterators)";
            } elsif ($fieldText eq "end") {
                warn "Unmatched iterator end in template!";
            } else  {
                $set = $fieldText;
                # look for case-sensitive end block
                if ($line =~ /\${@[Ee][Nn][Dd]}/) {
                    my $iblock .= $`;
                    $line = $';
                    $line_out .= iterate($set, $iblock, $quote);
                } else {
                    warn "Iterator block missing \@end to terminate!";
                } 
            }
        }

        # CASE 3: Mark Field
        elsif ($command eq "'") {
            if ($iterating eq "yes") {
                warn "Manually marking or unmarking while iterating makes no sense!";
            }
            $RSTE::marks{$fieldText} = "yes";   
        }

        # CASE 4: unmark Field
        elsif ($command eq "/") {
            if ($iterating eq "yes") {
                warn "Manually marking or unmarking while iterating makes no sense!";
            }
            $RSTE::marks{$fieldText} = "no";   
        }

        # CASE 5: Check for field present
        elsif ($command eq "?") {
            if (not $altText) {
                warn "Comparison without alt. text. (Does nothing.)";
            } elsif ($RSTE::values{$fieldText}) {
                $line_out .= $altText;
            } 
        }

        # CASE 6: Check for field not present
        elsif ($command eq "^") {
            if (not $altText) {
                warn "Comparison without alt. text. (Does nothing.)";
            } elsif (not $RSTE::values{$fieldText}) {
                $line_out .= $altText;
            } 
        }

        # CASE 7: Check for field missing (mandatory and not present)
        elsif ($command eq "!") {
            if (not $altText) {
                warn "Comparison without alt. text. (Does nothing.)";
            } elsif (defined $RSTE::missing{$fieldText}) {
                $line_out .= $altText;
            } 
        }

        # CASE 8: Check for field type mismatch
        elsif ($command eq "~") {
            if (not $altText) {
                warn "Comparison without alt. text. (Does nothing.)";
            } elsif (defined $RSTE::mismatch{$fieldText}) {
                $line_out .= $altText;
            } 
        }

    }
    return $line_out . $line;
}

# Iterate a template string over a set of fields.
# Parameter:
#   - name of set to iterate over
#   - template string to be repeated
#   - quoting mode
# Returns:
#   - long string of iterated strings
#
sub iterate($$) {
    my $set = $_[0];
    my $string = $_[1];
    my $quote = $_[2];
    my $line_out = "";
    my $fieldName;
    if ($set eq "all" or $set eq "unmarked") {
        foreach $fieldName (keys %RSTE::values) {
            if ($fieldName ne "kana frh iterator internal field name" and
                ($set eq "all" or $RSTE::marks{$fieldName} ne "yes"))     
            {
                $RSTE::iterName = $fieldName;
                insertPair("kana frh iterator internal field name", $RSTE::realnames{fieldName});
                $line_out .= renderString($string, $quote, "yes");
            }
        }
    return $line_out;
    }

    my %hashSet;
    if ($set eq "missing") {
        %hashSet = %RSTE::missing;
    }
    if ($set eq "mismatched") {
        %hashSet = %RSTE::mismatch;
    }    
    
    # we can add more sets here.

    if (scalar keys %hashSet > 0) {
        foreach $fieldName (keys %hashSet) {
            if ($fieldName ne "kana frh iterator internal field name")
            {
                $RSTE::iterName = $fieldName;
                insertPair("kana frh iterator internal field name", $fieldName);
                $line_out .= renderString($string, $quote, "yes");
            }
        }
    return $line_out;
    }

}    


# Returns a string with HTML/XML special characters replaced with entities.
# Parameter:
#   - string to quote
# Returns:
#   - quoted string
#
sub quoteStringHTML($) {
    my $string = $_[0];
    return $string if not $string;           # if string is blank, skip processing
    $string =~ s/[\x01-\x08\x0B\x0C\x0E-\x1F]//g; # strip low control chars except NULL and whitespace
    $string =~ s/&/&amp;/g;
    $string =~ s/>/&gt;/g;
    $string =~ s/</&lt;/g;
    $string =~ s/\"/&quot;/g;
#    $value =~ s/\'/&apos;/g;                # disabled here because we're dealing with HTML, primarily 
    return $string;
}

# URLencode a string. (NOT yet complete)
# Parameter:
#   - string to URLencode
# Returns:
#   - URLencoded string
#
sub quoteStringURL($) {
    my $string = $_[0];
    my $string_out = "";
    while ($string =~ /([^A-Za-z0-9])/ ) {   # \-_.!~*'()
        my $charVal = unpack "C", $1;
        $string_out .= $` . sprintf("%%%02X", $charVal);
        $string = $';        
        }
    return $string_out.$string;
}


# Throws an exception by invoking die().
# Optional parameter:
#   - error message
#
sub throwRSTEException(;$) {
    my $errorMessage = $_[0];
    warn "$errorMessage\n";
    die "$errorMessage\n";
}

