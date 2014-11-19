module B
  def ping
    puts "B::test"
  end
end
module C
  def ping
    puts "C::test"
    super
  end
end
module D
  def ping
    puts "D::test"
    super
  end
end
module E
  def ping
    puts "E::test"
    super
  end
end

class PartnerApi
  include B
  include C
  prepend D
  prepend E

  def ping
    puts "PartnerApi::test"
    super
  end
end


require 'pry'

require './partner_api_3'
