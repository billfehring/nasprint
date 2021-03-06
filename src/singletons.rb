#!/usr/bin/env ruby
# -*- encoding: utf-8 -*-

require 'jaro_winkler'

class Call
  def initialize(id, callsign, valid, haveLog, numQSOs)
    @id = id
    @callsign = callsign
    @valid = valid
    @haveLog = haveLog
    @numQSOs = numQSOs
  end
  
  attr_reader :id, :callsign, :valid, :haveLog, :numQSOs

  def to_s
    callsign.to_s
  end
end

class ResolveSingletons
  def initialize(db, contestID, cdb)
    @db = db
    @contestID = contestID
    @logIDs = cdb.logsForContest(contestID)
    @callsigns = queryCallsigns
    @callFromID = Hash.new
    @callsigns.each { |call|
      @callFromID[call.id] = call
    }
  end

  def toBool(val)
    (val and (val.to_i != 0))
  end

  ONE_BY_ONE = /\A[A-Z][0-9][A-Z]\Z/

  def queryCallsigns
    callList = Array.new
    res = @db.query("select c.id, c.basecall, c.validcall, c.logrecvd, count(*) as num from Callsign as c, Exchange as e, QSO as q where c.contestID = #{@contestID} and e.callID = c.id and e.id = q.recvdID group by c.id order by c.basecall asc;")
    res.each(:as => :array) { |row|
      callList << Call.new(row[0].to_i, row[1], (toBool(row[2]) or ONE_BY_ONE.match(row[1])), toBool(row[3]), row[4].to_i)
    }
    return callList
  end

  def possibleMatches(id, callsign, tolerance = 0.94)
    results = Array.new
    @callsigns.each { |call|
      if call.id != id and call.valid and (call.numQSOs >= 10 or call.haveLog) and JaroWinkler.distance(call.callsign, callsign) >= tolerance
        results << call
      end
    }
    results.empty? ? nil : results
  end

  def farMoreCommon(list, count)
    if list
      sorted = list.sort { |x,y| y.numQSOs <=> x.numQSOs }
      if (sorted[0].numQSOs >= 10) and (sorted[0].numQSOs >= 10*count) and sorted[0].haveLog
        return sorted[0]
      end
    end
    nil
  end

  def exchangeClose(qid, call)
    res = @db.query("select e.name, m.abbrev from QSO as q join Exchange as e on e.id = q.recvdID left join Multiplier as m on m.id = e.multiplierID where q.id = #{qid} limit 1;")
    res.each(:as => :array) { |row|
      ref = @db.query("select e.name, m.abbrev from Callsign as c join Log as l on (l.contestID = #{@contestID} and  c.id = l.callID) join QSO as q join Exchange as e on e.id = q.recvdID left join Multiplier as m on m.id = e.multiplierID where c.basecall = \"#{call}\" limit 1;")
      print "exchangeClose1 #{row[0]} #{row[1]}\n"
      ref.each(:as => :array) { |refrow|
        print "exchangeClose2 #{refrow[0]} #{refrow[1]}\n"
        if JaroWinkler.distance(row[0], refrow[0]) >= 0.92 and JaroWinkler.distance(row[1], refrow[1]) >= 0.92
          return true
        end
      }
    }
    false
  end


  def resolve
    res = @db.query("select distinct q.id from QSO as q, Exchange as e where matchType = 'None' and q.recvdID = e.id and (e.multiplierID is null or e.serial is null or e.name is null);")
    res.each( :as => :array) { |row|
      @db.query("update QSO set matchType = 'Removed', comment='Incomplete exchanged received.' where id = #{row[0]} limit 1;")
    }
    res = @db.query("select q.id, e.callID, e.serial from QSO as q, Exchange as e where q.logID in (#{@logIDs.join(", ")}) and q.matchType = 'None' and e.id = q.recvdID order by q.id asc;")
    res.each(:as => :array) { |row|
      call = @callFromID[row[1]]
      if call
        if not call.valid and call.numQSOs <= 5
          # illegal callsign
          list = possibleMatches(call.id, call.callsign)
          if list
            @db.query("update QSO set matchType = 'Removed', comment='Busted callsign - potential matches: #{list.join(" ")}.' where id = #{row[0]} limit 1;")
          else
            @db.query("update QSO set matchType = 'Removed', comment='Illegal callsign not close to known participants.' where id = #{row[0]} limit 1;")
          end
        else
          if call.numQSOs >= 10 or (call.valid and call.numQSOs >= 5)
            @db.query("update QSO set matchType = 'Bye' where id = #{row[0]} limit 1;")
          else
            list = possibleMatches(call.id, call.callsign)
            mc = farMoreCommon(list, call.numQSOs)
            if mc and exchangeClose(row[0],mc)
              @db.query("update QSO set matchType = 'Removed', comment='Busted call - likely match: #{mc.callsign}.'  where id = #{row[0]} limit 1;")
            else
              @db.query("update QSO set matchType = 'Bye' where id = #{row[0]} limit 1;")
            end
          end
        end
      else
        @db.query("update QSO set matchType = 'Removed', comment='Unknown callsign ID in record.' where id = #{row[0]} limit 1;")
      end
    }
  end

  def finalDupeCheck
    print "Starting final dupe check: #{Time.now.to_s}\n"
    res = @db.query("select q1.id, q2.id from QSO as q1, QSO as q2, Exchange as e1, Exchange as e2 where q1.logID in (#{@logIDs.join(",")}) and q2.logID in (#{@logIDs.join(",")}) and q1.id < q2.id and q1.logID = q2.logID and q1.matchType in ('Full','Bye') and q2.matchType in ('Full','Bye') and q1.band = q2.band and e1.id = q1.recvdID and e2.id = q2.recvdID and e1.callID = e2.callID order by q1.id;")
    count = 0
    res.each(:as => :array) { |row|
      @db.query("update QSO set matchType = 'Dupe' where id = #{row[1]} and matchType in ('Full','Bye') limit 1;")
      count = count + @db.affected_rows
    }
    print "Done final dupe check: #{Time.now.to_s}\n"
    count
  end
end
