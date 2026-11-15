# Smart Place - idempotent installer for RouterOS 7.24.6
# Creates independent SMS handler and device cron; only the SMS handler uses the modem.
# Keeps flash/smart-place-device-*.json and flash/smart-place-trusted-numbers.txt untouched.
# BOTH schedulers remain disabled after every import.
# Scheduler policy MUST include sensitive: RouterOS 7.24.6 returned nil from
# /file get <id> contents without it (confirmed via Scheduler probe).

# Disable all known old and new Smart Place schedulers first.
:foreach oldSchedule in={"smart-place";"smart-place-tick";"smart-place-sms-tick";"smart-place-alert-tick";"check-sms-inbox";"smart-place-cron"} do={
    :local ids [/system scheduler find where name=$oldSchedule];
    :if ([:len $ids] > 0) do={ /system scheduler disable $ids; }
}

# Refuse to uninstall a script while it is running.
:foreach oldScript in={"smart-place-worker";"smart-place-selftest";"smart-place-sms-handler";"smart-place-cron"} do={
    :if ([/system script job print count-only where script=$oldScript] > 0) do={
        :error ("SmartPlace: running job " . $oldScript . "; stop/finish before reinstalling");
    }
}

# Replace precisely the owned components. Do not touch other scripts.
:foreach oldSchedule in={"smart-place";"smart-place-tick";"smart-place-sms-tick";"smart-place-alert-tick";"check-sms-inbox";"smart-place-cron"} do={
    :local ids [/system scheduler find where name=$oldSchedule];
    :if ([:len $ids] > 0) do={ /system scheduler remove $ids; }
}
:foreach oldScript in={"smart-place-worker";"smart-place-selftest";"smart-place-sms-handler";"smart-place-cron"} do={
    :local ids [/system script find where name=$oldScript];
    :if ([:len $ids] > 0) do={ /system script remove $ids; }
}

# Runtime state in RAM, not flash. Prior events are dropped on reinstall.
:global spLastCheck;
:set spLastCheck [:toarray ""];
:global spPriorAlert;
:set spPriorAlert [:toarray ""];
:global spPendingAlerts;
:set spPendingAlerts [:toarray ""];
:global spHandledSms;
:set spHandledSms [:toarray ""];

/system script add name="smart-place-selftest" policy=ftp,read,write,test,policy source={
    :local ids [/file find where name="flash/smart-place-device-guard.json"];
    :if ([:len $ids] != 1) do={ :error "guard JSON missing in flash"; }
    :local configText [/file get [:pick $ids 0] contents];
    :if (([:typeof $configText] != "str") or ([:len $configText] < 2)) do={ :error "guard config missing or empty"; }
    :local conf [:deserialize from=json value=$configText options=json.no-string-conversion];
    # Repeat the EXACT configuration-loading patterns used by SMS and cron.
    :local confPath "flash/smart-place-device-guard.json";
    :local dynamicIds [/file find where name=$confPath];
    :if ([:len $dynamicIds] != 1) do={:error "Worker config lookup failed"}
    :local dynamicText [/file get [:pick $dynamicIds 0] contents];
    :local dynamicConfig [:deserialize from=json value=$dynamicText options=json.no-string-conversion];
    :if (($dynamicConfig->"ip") != ($conf->"ip")) do={:error "Worker config IP mismatch"}
    :put ("Worker config loader: OK (" . [:len $dynamicText] . " bytes)");
    :local cronFound false;
    :foreach cronId in=[/file find where name~"smart-place-device-"] do={
        :local cronPath [/file get $cronId name];
        :if ($cronPath = $confPath) do={
            :local cronText [/file get $cronId contents];
            :local cronConfig [:deserialize from=json value=$cronText options=json.no-string-conversion];
            :if (($cronConfig->"name") != "guard") do={:error "Cron config name mismatch"}
            :set cronFound true;
            :put ("Cron config loader: OK (" . [:len $cronText] . " bytes)");
        }
    }
    :if ($cronFound = false) do={:error "Cron cannot enumerate guard config"}
    :put ("name=" . ($conf->"name") . " ip=" . ($conf->"ip"));
    :put ("set mode=" . ($conf->"set") . " get mode=" . ($conf->"get"));
    :put "Testing GET only; NO POST and NO SMS";
    :put "Worker GET and cron use direct RAM-file fetch (no fetch helper)";
    :put "HTTP transport: RAM file (output=file, no as-value, no keep-result)";
    :local temp "smart-place-selftest-http.txt";
    :local old [/file find where name=$temp];
    :if ([:len $old] > 0) do={ /file remove $old; }
    :local responseText "";
    :onerror fetchError in={
        /tool fetch url=("http://" . ($conf->"ip") . "/") http-method=get output=file dst-path=$temp;
        :local downloaded [/file find where name=$temp];
        :if ([:len $downloaded] != 1) do={:error "GET did not create RAM response file"}
        :set responseText [/file get [:pick $downloaded 0] contents];
    } do={
        :local residue [/file find where name=$temp];
        :if ([:len $residue] > 0) do={ /file remove $residue; }
        :error ("GET failed: " . $fetchError);
    }
    :local residue [/file find where name=$temp];
    :if ([:len $residue] > 0) do={ /file remove $residue; }
    :if ([:len $responseText] = 0) do={:error "GET returned empty body"}
    :local obj [:deserialize from=json value=$responseText options=json.no-string-conversion];
    :if ([:typeof $obj] != "array") do={ :error "GET root is not a JSON object or array" }
    :foreach k,v in=$obj do={
        :local vs [:tostr $v];
        :if ([:typeof $v] = "array") do={:set vs [:serialize to=json value=$v options=json.no-string-conversion]}
        :if ([:typeof $v] = "nil") do={:set vs "null"}
        :put ($k . " = " . $vs);
    }
    :put "Dry-run key/value POST body: ";
    :local testMap [:toarray ""];
    :set ($testMap->"d") 2;
    :set ($testMap->"r") 4;
    :put [:serialize to=json value=$testMap options=json.no-string-conversion];
    :put "Self-test finished";
}

/system script add name="smart-place-sms-handler" policy=ftp,read,write,test,policy source={
    # SMS reception, replies and alert delivery ONLY. No polling of ESP32 here.
    # Non-numeric service senders (e.g. Kyivstar) are ignored and never replied to.
    :local smsPort "lte1";
    :local base "flash/";
    :local trustedName ($base . "smart-place-trusted-numbers.txt");
    :local prefix ($base . "smart-place-device-");

    :if ([/system script job print count-only where script=[:jobname]] > 1) do={
        :log warning "SmartPlace: SMS handler already running; skip";
        :return;
    }

    # Return a readable first-level JSON representation (or raw response).
    :local formatResponse do={
        :local raw $1;
        :local format $2;
        :if ($format = "raw") do={ :return $raw }
        :if ($format != "flat") do={ :error "Unsupported GET format" }
        :local parsed [:deserialize from=json value=$raw options=json.no-string-conversion];
        :if ([:typeof $parsed] != "array") do={ :return [:tostr $parsed] }
        :local out "";
        :foreach k,v in=$parsed do={
            :local s [:tostr $v];
            :if ([:typeof $v] = "array") do={ :set s [:serialize to=json value=$v options=json.no-string-conversion] }
            :if ([:typeof $v] = "nil") do={ :set s "null" }
            :set out ($out . $k . " = " . $s . "\n");
        }
        :return $out;
    }

    # Parse SET auto: raw JSON array/object OR key-value tokens.
    :local makePayload do={
        :local raw $1;
        :local mode $2;
        :local wrap $3;
        :if ($mode != "auto") do={ :error "Unsupported SET format" }
        :if ([:len $raw] = 0) do={ :error "SET payload empty" }
        :local lead [:pick $raw 0 1];
        :if (($lead = "[") or ($lead = "{")) do={
            :local obj [:deserialize from=json value=$raw options=json.no-string-conversion];
            :if ([:typeof $obj] != "array") do={ :error "JSON root must be object or array" }
            :if (($lead = "[") and ([:len $wrap] > 0)) do={
                :local wrapped [:toarray ""];
                :set ($wrapped->$wrap) $obj;
                :return [:serialize to=json value=$wrapped options=json.no-string-conversion];
            }
            :return [:serialize to=json value=$obj options=json.no-string-conversion];
        }
        :local tokens [:toarray ""];
        :local rest $raw;
        :while ([:len $rest] > 0) do={
            :local pos [:find $rest " "];
            :local tok "";
            :if ([:typeof $pos] = "nil") do={
                :set tok $rest;
                :set rest "";
            } else={
                :set tok [:pick $rest 0 $pos];
                :set rest [:pick $rest ($pos + 1) [:len $rest]];
            }
            :if ([:len $tok] > 0) do={ :set tokens ($tokens, $tok) }
        }
        :if ([:len $tokens] = 0) do={ :error "No SET tokens" }
        :if (([:len $tokens] % 2) != 0) do={ :error "SET requires key/value pairs" }
        :local result [:toarray ""];
        :for i from=0 to=([:len $tokens] - 1) step=2 do={
            :local key ($tokens->$i);
            :if ([:len $key] = 0) do={ :error "Empty SET key" }
            :for j from=0 to=([:len $key] - 1) do={
                :local ch [:pick $key $j ($j+1)];
                :if ([:typeof [:find "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-" $ch]] = "nil") do={
                    :error "Bad SET key";
                }
            }
            :local valueText ($tokens->($i + 1));
            :local parsedValue $valueText;
            :do {
                :set parsedValue [:deserialize from=json value=$valueText options=json.no-string-conversion];
            } on-error={
                :set parsedValue $valueText;
            }
            :set ($result->$key) $parsedValue;
        }
        :return [:serialize to=json value=$result options=json.no-string-conversion];
    }

    # Send one or multiple *separate* short GSM7 messages (not concatenated SMS).
    # Output should use ASCII. 64 chars/page is conservative for GSM7 escape pairs.
    # Space modem submissions to reduce LTE modem busy/timeout errors.
    # An SMS send error can be ambiguous (modem may have submitted it), so we
    # intentionally DO NOT auto-retry: retries could duplicate SMS content.
    :local sendPages do={
        :local number $1;
        :local data $2;
        :local portName $3;
        :local title $4;
        :local safeTitle [:pick $title 0 20];
        :if ([:len $data] = 0) do={ :set data "EMPTY RESPONSE" }
        :local width 64;
        :local cap 8;
        :if ([:len $data] > ($width * $cap)) do={
            :set data ([:pick $data 0 (($width * $cap) - 12)] . " [TRUNCATED]");
        }
        :local pages 0;
        :local remaining [:len $data];
        :while ($remaining > 0) do={ :set pages ($pages + 1); :set remaining ($remaining - $width) }
        :local success true;
        :for i from=1 to=$pages do={
            :local a (($i - 1) * $width);
            :local b ($a + $width);
            :local textPart [:pick $data $a $b];
            :local messageText ($safeTitle . " " . $i . "/" . $pages . ": " . $textPart);
            :onerror smsError in={
                /tool sms send port=$portName phone-number=$number message=$messageText status-report-request=no;
            } do={
                :set success false;
                :log warning ("SmartPlace: SMS part " . $i . "/" . $pages . " failed to " . $number . ": " . $smsError);
            }
            # Give lte1 breathing room before the next SMS submission.
            :if ($i < $pages) do={ :delay 3s; }
        }
        :return $success;
    }

    # Trusted phones: missing/malformed file = fail closed.
    :local ids [/file find where name=$trustedName];
    :if ([:len $ids] != 1) do={
        :log error "SmartPlace: trusted-numbers missing or ambiguous; DENY ALL";
        :return;
    }
    :local trustedText [/file get [:pick $ids 0] contents];
    :local publicAccess ([:len $trustedText] = 0);
    :local trustedList [:toarray ""];
    :if ($publicAccess = false) do={
        :local rest [:tolf $trustedText];
        :local bad false;
        :while ([:len $rest] > 0) do={
            :local idx [:find $rest "\n"];
            :local number "";
            :if ([:typeof $idx] = "nil") do={
                :set number $rest;
                :set rest "";
            } else={
                :set number [:pick $rest 0 $idx];
                :set rest [:pick $rest ($idx + 1) [:len $rest]];
            }
            :if ([:len $number] > 0) do={
                :if ([:len $number] < 9) do={:set bad true}
                :if ([:len $number] > 16) do={:set bad true}
                :if ([:pick $number 0 1] != "+") do={:set bad true}
                :for j from=1 to=([:len $number] - 1) do={
                    :local ch [:pick $number $j ($j + 1)];
                    :if ([:typeof [:find "0123456789" $ch]] = "nil") do={:set bad true}
                }
                :local already false;
                :foreach x in=$trustedList do={:if ($x = $number) do={:set already true}}
                :if ($already = false) do={:set trustedList ($trustedList, $number)}
            }
        }
        :if (($bad = true) or ([:len $trustedList] = 0)) do={
            :log error "SmartPlace: invalid trusted list; DENY ALL";
            :return;
        }
    }

    # Process only supported commands from real international phone numbers.
    # An operator alphanumeric sender is NEVER eligible for an SMS reply.
    # Unknown / corrupted / Cyrillic messages are left in inbox for manual review.
    :global spHandledSms;
    :if ([:typeof $spHandledSms] != "array") do={ :set spHandledSms [:toarray ""]; }
    :foreach msgId in=[/tool sms inbox find] do={
        :local smsTimestamp [/tool sms inbox get $msgId timestamp];
        :local idKey ([:tostr $msgId] . "-" . [:tostr $smsTimestamp]);
        :if (($spHandledSms->$idKey) != true) do={
            :local caller [/tool sms inbox get $msgId phone];
            :local textBody [/tool sms inbox get $msgId message];
            :local validPhone true;
            :if (([:len $caller] < 9) or ([:len $caller] > 16) or ([:pick $caller 0 1] != "+")) do={:set validPhone false}
            :if ($validPhone = true) do={
                :for j from=1 to=([:len $caller] - 1) do={
                    :local ch [:pick $caller $j ($j + 1)];
                    :if ([:typeof [:find "0123456789" $ch]] = "nil") do={:set validPhone false}
                }
            }
            :if ($validPhone = true) do={
                :local p1 [:find $textBody " "];
                :if ([:typeof $p1] != "nil") do={
                    :local commandName [:pick $textBody 0 $p1];
                    :if (($commandName = "get") or ($commandName = "set") or ($commandName = "help")) do={
                        :local allowed $publicAccess;
                        :foreach n in=$trustedList do={:if ($n = $caller) do={:set allowed true}}
                        :if ($allowed = false) do={
                            :log warning ("SmartPlace: command ignored from non-trusted number");
                        } else={
                            :local resultText "";
                            :local device "";
                            :local stage "parse";
                            :onerror commandError in={
                                :local remainder [:pick $textBody ($p1 + 1) [:len $textBody]];
                                :local p2 [:find $remainder " "];
                                :local payload "";
                                :if ([:typeof $p2] = "nil") do={
                                    :set device $remainder;
                                } else={
                                    :set device [:pick $remainder 0 $p2];
                                    :set payload [:pick $remainder ($p2 + 1) [:len $remainder]];
                                }
                                :if ([:len $device] = 0) do={:error "Missing device name"}
                                :for j from=0 to=([:len $device]-1) do={
                                    :local ch [:pick $device $j ($j+1)];
                                    :if ([:typeof [:find "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-" $ch]] = "nil") do={:error "Bad device name"}
                                }
                                :if (($commandName != "set") and ([:len $payload] > 0)) do={:error "Extra arguments are not allowed"}
                                :local confFile ($prefix . $device . ".json");
                                :local found [/file find where name=$confFile];
                                :if ([:len $found] != 1) do={:error "Device config not found"}
                                :set stage "config JSON";
                                :local configText [/file get [:pick $found 0] contents];
                                :if (([:typeof $configText] != "str") or ([:len $configText] < 2)) do={:error "Empty device config"}
                                :local conf [:deserialize from=json value=$configText options=json.no-string-conversion];
                                :if (($conf->"name") != $device) do={:error "Config name mismatch"}
                                :if ($commandName = "help") do={
                                    :set stage "HELP";
                                    :set resultText ($conf->"help");
                                }
                                :if ($commandName = "get") do={
                                    :set stage "GET";
                                    :local ipAddr ($conf->"ip");
                                    :local temp "smart-place-sms-http.txt";
                                    :local stale [/file find where name=$temp];
                                    :if ([:len $stale] > 0) do={/file remove $stale}
                                    :local raw "";
                                    :onerror fetchError in={
                                        /tool fetch url=("http://" . $ipAddr . "/") http-method=get output=file dst-path=$temp;
                                        :local got [/file find where name=$temp];
                                        :if ([:len $got] != 1) do={:error "GET response file missing"}
                                        :set raw [/file get [:pick $got 0] contents];
                                    } do={
                                        :local remains [/file find where name=$temp];
                                        :if ([:len $remains] > 0) do={/file remove $remains}
                                        :error ("GET fetch: " . $fetchError);
                                    }
                                    :local remains [/file find where name=$temp];
                                    :if ([:len $remains] > 0) do={/file remove $remains}
                                    :set stage "GET JSON";
                                    :set resultText [$formatResponse $raw ($conf->"get")];
                                }
                                :if ($commandName = "set") do={
                                    :set stage "SET parse";
                                    :local body [$makePayload $payload ($conf->"set") ($conf->"wrap")];
                                    :set stage "SET HTTP";
                                    :local temp "smart-place-sms-http.txt";
                                    :local stale [/file find where name=$temp];
                                    :if ([:len $stale] > 0) do={/file remove $stale}
                                    :local raw "";
                                    :onerror fetchError in={
                                        /tool fetch url=("http://" . ($conf->"ip") . "/") http-method=post http-header-field="Content-Type:application/json" http-data=$body output=file dst-path=$temp;
                                        :local got [/file find where name=$temp];
                                        :if ([:len $got] != 1) do={:error "POST response file missing"}
                                        :set raw [/file get [:pick $got 0] contents];
                                    } do={
                                        :local remains [/file find where name=$temp];
                                        :if ([:len $remains] > 0) do={/file remove $remains}
                                        :error ("POST fetch: " . $fetchError);
                                    }
                                    :local remains [/file find where name=$temp];
                                    :if ([:len $remains] > 0) do={/file remove $remains}
                                    :if ([:len $raw] = 0) do={
                                        :set resultText "POST OK (empty response)";
                                    } else={
                                        :set stage "SET response JSON";
                                        :set resultText [$formatResponse $raw ($conf->"get")];
                                    }
                                }
                            } do={
                                :set resultText ("ERR: " . $stage . " failed");
                                :log warning ("SmartPlace: " . $stage . " " . $device . " failed: " . $commandError);
                            }
                            :local ok [$sendPages $caller $resultText $smsPort $device];
                            :if ($ok = false) do={:log warning "SmartPlace: reply not fully delivered"}
                        }
                        # Mark as handled BEFORE attempting deletion; if modem refuses
                        # delete, next tick must not execute the same POST again.
                        :set ($spHandledSms->$idKey) true;
                        :onerror deleteError in={
                            /tool sms inbox remove $msgId;
                        } do={
                            :log warning ("SmartPlace: inbox delete failed, deduplicated in RAM: " . $deleteError);
                        }
                    }
                }
            }
        }
    }

    # Only this SMS handler is allowed to send queued alerts. This avoids
    # two scripts submitting modem commands at the same time.
    :global spPendingAlerts;
    :if ([:typeof $spPendingAlerts] != "array") do={:set spPendingAlerts [:toarray ""]}
    :local pending $spPendingAlerts;
    :set spPendingAlerts [:toarray ""];
    :if ([:len $trustedList] > 0) do={
        :foreach device,report in=$pending do={
            :foreach number in=$trustedList do={
                :local ok [$sendPages $number ("ALERT " . $device . "!\n" . $report) $smsPort $device];
                :if ($ok = false) do={:log warning ("SmartPlace: alert SMS failed for " . $device)}
            }
        }
    }
}

/system script add name="smart-place-cron" policy=ftp,read,write,test,policy source={
    # Poll JSON devices only; NEVER send SMS directly. Queue alerts in RAM.
    :local prefix "flash/smart-place-device-";
    :if ([/system script job print count-only where script=[:jobname]] > 1) do={
        :log warning "SmartPlace: device cron already running; skip";
        :return;
    }
    :global spLastCheck;
    :global spPriorAlert;
    :global spPendingAlerts;
    :if ([:typeof $spLastCheck] != "array") do={:set spLastCheck [:toarray ""]}
    :if ([:typeof $spPriorAlert] != "array") do={:set spPriorAlert [:toarray ""]}
    :if ([:typeof $spPendingAlerts] != "array") do={:set spPendingAlerts [:toarray ""]}
    :local formatResponse do={
        :local raw $1;
        :local format $2;
        :if ($format = "raw") do={:return $raw}
        :if ($format != "flat") do={:error "Unsupported GET format"}
        :local parsed [:deserialize from=json value=$raw options=json.no-string-conversion];
        :if ([:typeof $parsed] != "array") do={:return [:tostr $parsed]}
        :local out "";
        :foreach k,v in=$parsed do={
            :local s [:tostr $v];
            :if ([:typeof $v] = "array") do={:set s [:serialize to=json value=$v options=json.no-string-conversion]}
            :if ([:typeof $v] = "nil") do={:set s "null"}
            :set out ($out . $k . " = " . $s . "\n");
        }
        :return $out;
    }
    :local now [:timestamp];
    :foreach fileId in=[/file find where name~"smart-place-device-"] do={
        :local fileName [/file get $fileId name];
        :if (([:len $fileName] > ([:len $prefix] + 5)) and ([:pick $fileName 0 [:len $prefix]] = $prefix) and ([:pick $fileName ([:len $fileName] - 5) [:len $fileName]] = ".json")) do={
            :onerror cronError in={
                :local configText [/file get $fileId contents];
                :if (([:typeof $configText] != "str") or ([:len $configText] < 2)) do={:error "Empty device config"}
                :local conf [:deserialize from=json value=$configText options=json.no-string-conversion];
                :local device ($conf->"name");
                :if ([:typeof $device] != "str") do={:error "Bad device name"}
                :if (($prefix . $device . ".json") != $fileName) do={:error "Device filename mismatch"}
                :if (($conf->"alert") = true) do={
                    :local freq ($conf->"interval");
                    :if ([:typeof $freq] != "num") do={:error "Bad interval type"}
                    :if ($freq < 20) do={:error "Interval must be >=20s"}
                    :local prev ($spLastCheck->$device);
                    :local due false;
                    :if ([:typeof $prev] = "nil") do={:set due true} else={
                        :if (($now - $prev) >= [:totime ($freq . "s")]) do={:set due true}
                    }
                    :if ($due = true) do={
                        :set ($spLastCheck->$device) $now;
                        :local temp "smart-place-cron-http.txt";
                        :local stale [/file find where name=$temp];
                        :if ([:len $stale] > 0) do={/file remove $stale}
                        :local raw "";
                        :onerror fetchError in={
                            /tool fetch url=("http://" . ($conf->"ip") . "/") http-method=get output=file dst-path=$temp;
                            :local got [/file find where name=$temp];
                            :if ([:len $got] != 1) do={:error "Cron response file missing"}
                            :set raw [/file get [:pick $got 0] contents];
                        } do={
                            :local remains [/file find where name=$temp];
                            :if ([:len $remains] > 0) do={/file remove $remains}
                            :error ("Cron GET fetch: " . $fetchError);
                        }
                        :local remains [/file find where name=$temp];
                        :if ([:len $remains] > 0) do={/file remove $remains}
                        :local status [:deserialize from=json value=$raw options=json.no-string-conversion];
                        :if ([:typeof $status] != "array") do={:error "Status not JSON object"}
                        :if (($status->"alert") = true) do={
                            :if (($spPriorAlert->$device) != true) do={
                                :local report [$formatResponse $raw ($conf->"get")];
                                :set ($spPendingAlerts->$device) $report;
                                :set ($spPriorAlert->$device) true;
                                :log info ("SmartPlace: queued alert " . $device);
                            }
                        } else={
                            :set ($spPriorAlert->$device) false;
                        }
                    }
                }
            } do={
                :log warning ("SmartPlace: cron failure for " . $fileName . ": " . $cronError);
            }
        }
    }
}

# Independent schedulers; disabled after every installation.
# The sensitive permission is REQUIRED to read /file contents from Scheduler
# on the tested Chateau / RouterOS 7.24.6. Do not remove it when editing.
/system scheduler add name="smart-place-sms-tick" interval=20s start-time=00:00:00 on-event="/system script run smart-place-sms-handler" disabled=yes policy=ftp,read,write,test,policy,sensitive
/system scheduler add name="smart-place-alert-tick" interval=20s start-time=00:00:00 on-event="/system script run smart-place-cron" disabled=yes policy=ftp,read,write,test,policy,sensitive
:put "SmartPlace installed: SMS handler + alert cron, 2 DISABLED schedulers";
:put "Device configs and trusted numbers were NOT modified";
